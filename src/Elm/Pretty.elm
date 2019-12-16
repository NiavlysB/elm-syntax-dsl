module Elm.Pretty exposing
    ( prepareLayout, pretty
    , prettyImports, prettyExposing
    , prettyDeclaration, prettyFun, prettyTypeAlias, prettyCustomType, prettyPortDeclaration, prettyDestructuring
    , prettySignature, prettyPattern, prettyExpression, prettyTypeAnnotation
    )

{-| Elm.Pretty is a pretty printer for Elm syntax trees. It makes use of
`the-sett/elm-pretty-printer` to best fit the code to a given page width in
characters.

It aims to output code that is fully stable with respect to `elm-format` in the
sense that running `elm-format` on the output should have no effect at all. The
advantage of this is that if generated code moves to being edited by hand, there
will not be a large white-space only diff created when `elm-format` is applied.

To print the `Doc` created by the `pretty` functions, `the-sett/elm-pretty-printer`
is used:

    import Elm.Pretty
    import Pretty


    -- Fit to a page width of 120 characters
    elmAsString =
        Elm.Pretty.prepareLayout someFile
            |> Pretty.pretty 120

There is also a helper `pretty` function in this module that can go straight to
a `String`, for convenience:

    -- Fit to a page width of 120 characters
    elmAsString =
        Elm.Pretty.pretty 120 someFile


# Pretty prints an entire Elm file.

@docs prepareLayout, pretty


# Pretty printing snippets of Elm.

@docs prettyImports, prettyExposing
@docs prettyDeclaration, prettyFun, prettyTypeAlias, prettyCustomType, prettyPortDeclaration, prettyDestructuring
@docs prettySignature, prettyPattern, prettyExpression, prettyTypeAnnotation

-}

import Bool.Extra
import Elm.CodeGen exposing (Declaration(..), File)
import Elm.Comments
import Elm.Syntax.Declaration
import Elm.Syntax.Documentation exposing (Documentation)
import Elm.Syntax.Exposing exposing (ExposedType, Exposing(..), TopLevelExpose(..))
import Elm.Syntax.Expression exposing (Case, CaseBlock, Expression(..), Function, FunctionImplementation, Lambda, LetBlock, LetDeclaration(..), RecordSetter)
import Elm.Syntax.File
import Elm.Syntax.Import exposing (Import)
import Elm.Syntax.Infix exposing (Infix, InfixDirection(..))
import Elm.Syntax.Module exposing (DefaultModuleData, EffectModuleData, Module(..))
import Elm.Syntax.ModuleName exposing (ModuleName)
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern exposing (Pattern(..), QualifiedNameRef)
import Elm.Syntax.Range exposing (Location, Range, emptyRange)
import Elm.Syntax.Signature exposing (Signature)
import Elm.Syntax.Type exposing (Type, ValueConstructor)
import Elm.Syntax.TypeAlias exposing (TypeAlias)
import Elm.Syntax.TypeAnnotation exposing (RecordDefinition, RecordField, TypeAnnotation(..))
import Hex
import ImportsAndExposing
import Maybe.Extra
import Pretty exposing (Doc)
import Util exposing (denode, denodeAll, denodeMaybe, nodify, nodifyAll, nodifyMaybe)


{-| Prepares a file of Elm code for layout by the pretty printer.

Note that the `Doc` type returned by this is a `Pretty.Doc`. This can be printed
to a string by the `the-sett/elm-pretty-printer` package.

These `Doc` based functions are exposed in case you want to pretty print some
Elm inside something else with the pretty printer. The `pretty` function can be
used to go directly from a `File` to a `String`, if that is more convenient.

-}
prepareLayout : Int -> File -> Doc
prepareLayout width file =
    let
        layoutDeclComments decls =
            List.map
                (prettyDocComment width)
                decls

        ( innerFile, tags ) =
            case file.comments of
                Just comment ->
                    let
                        ( fileCommentStr, innerTags ) =
                            Elm.Comments.prettyFileComment width comment
                    in
                    ( { moduleDefinition = file.moduleDefinition
                      , imports = file.imports
                      , declarations = layoutDeclComments file.declarations |> nodifyAll
                      , comments = nodifyAll [ fileCommentStr ]
                      }
                    , innerTags
                    )

                Nothing ->
                    ( { moduleDefinition = file.moduleDefinition
                      , imports = file.imports
                      , declarations = layoutDeclComments file.declarations |> nodifyAll
                      , comments = []
                      }
                    , []
                    )
    in
    prettyModule (denode innerFile.moduleDefinition)
        |> Pretty.a Pretty.line
        |> Pretty.a Pretty.line
        |> Pretty.a (prettyComments (denodeAll innerFile.comments))
        |> Pretty.a (importsPretty innerFile)
        |> Pretty.a (prettyDeclarations (denodeAll innerFile.declarations))


importsPretty : Elm.Syntax.File.File -> Doc
importsPretty file =
    case file.imports of
        [] ->
            Pretty.line

        _ ->
            prettyImports (denodeAll file.imports)
                |> Pretty.a Pretty.line
                |> Pretty.a Pretty.line
                |> Pretty.a Pretty.line


{-| Prints a file of Elm code to the given page width, making use of the pretty
printer.
-}
pretty : Int -> File -> String
pretty width file =
    prepareLayout width file
        |> Pretty.pretty width


prettyModule : Module -> Doc
prettyModule mod =
    case mod of
        NormalModule defaultModuleData ->
            prettyDefaultModuleData defaultModuleData

        PortModule defaultModuleData ->
            prettyPortModuleData defaultModuleData

        EffectModule effectModuleData ->
            prettyEffectModuleData effectModuleData


prettyModuleName : ModuleName -> Doc
prettyModuleName name =
    List.map Pretty.string name
        |> Pretty.join dot


prettyModuleNameDot : ModuleName -> Doc
prettyModuleNameDot name =
    case name of
        [] ->
            Pretty.empty

        _ ->
            List.map Pretty.string name
                |> Pretty.join dot
                |> Pretty.a dot


prettyModuleNameAlias : ModuleName -> Doc
prettyModuleNameAlias name =
    case name of
        [] ->
            Pretty.empty

        _ ->
            Pretty.string "as "
                |> Pretty.a (List.map Pretty.string name |> Pretty.join dot)


prettyDefaultModuleData : DefaultModuleData -> Doc
prettyDefaultModuleData moduleData =
    Pretty.words
        [ Pretty.string "module"
        , prettyModuleName (denode moduleData.moduleName)
        , prettyExposing (denode moduleData.exposingList)
        ]


prettyPortModuleData : DefaultModuleData -> Doc
prettyPortModuleData moduleData =
    Pretty.words
        [ Pretty.string "port module"
        , prettyModuleName (denode moduleData.moduleName)
        , prettyExposing (denode moduleData.exposingList)
        ]


prettyEffectModuleData : EffectModuleData -> Doc
prettyEffectModuleData moduleData =
    let
        prettyCmdAndSub maybeCmd maybeSub =
            case ( maybeCmd, maybeSub ) of
                ( Nothing, Nothing ) ->
                    Nothing

                ( Just cmdName, Just subName ) ->
                    [ Pretty.string "where { command ="
                    , Pretty.string cmdName
                    , Pretty.string ","
                    , Pretty.string "subscription ="
                    , Pretty.string subName
                    , Pretty.string "}"
                    ]
                        |> Pretty.words
                        |> Just

                ( Just cmdName, Nothing ) ->
                    [ Pretty.string "where { command ="
                    , Pretty.string cmdName
                    , Pretty.string "}"
                    ]
                        |> Pretty.words
                        |> Just

                ( Nothing, Just subName ) ->
                    [ Pretty.string "where { subscription ="
                    , Pretty.string subName
                    , Pretty.string "}"
                    ]
                        |> Pretty.words
                        |> Just
    in
    Pretty.words
        [ Pretty.string "effect module"
        , prettyModuleName (denode moduleData.moduleName)
        , prettyCmdAndSub (denodeMaybe moduleData.command) (denodeMaybe moduleData.subscription)
            |> prettyMaybe identity
        , prettyExposing (denode moduleData.exposingList)
        ]


prettyComments : List String -> Doc
prettyComments comments =
    case comments of
        [] ->
            Pretty.empty

        _ ->
            List.map Pretty.string comments
                |> Pretty.lines
                |> Pretty.a Pretty.line
                |> Pretty.a Pretty.line


{-| Pretty prints a list of import statements.

The list will be de-duplicated and sorted.

-}
prettyImports : List Import -> Doc
prettyImports imports =
    ImportsAndExposing.sortAndDedupImports imports
        |> List.map prettyImport
        |> Pretty.lines


prettyImport : Import -> Doc
prettyImport import_ =
    Pretty.join Pretty.space
        [ Pretty.string "import"
        , prettyModuleName (denode import_.moduleName)
        , prettyMaybe prettyModuleNameAlias (denodeMaybe import_.moduleAlias)
        , prettyMaybe prettyExposing (denodeMaybe import_.exposingList)
        ]


{-| Pretty prints the contents of an exposing statement, as found on a module or import
statement.

The exposed values will be de-duplicated and sorted.

-}
prettyExposing : Exposing -> Doc
prettyExposing exposing_ =
    let
        exposings =
            case exposing_ of
                All _ ->
                    Pretty.string ".." |> Pretty.parens

                Explicit tll ->
                    ImportsAndExposing.sortAndDedupExposings (denodeAll tll)
                        |> prettyTopLevelExposes
                        |> Pretty.parens
    in
    Pretty.string "exposing"
        |> Pretty.a Pretty.space
        |> Pretty.a exposings


prettyTopLevelExposes : List TopLevelExpose -> Doc
prettyTopLevelExposes exposes =
    List.map prettyTopLevelExpose exposes
        |> Pretty.join (Pretty.string ", ")


prettyTopLevelExpose : TopLevelExpose -> Doc
prettyTopLevelExpose tlExpose =
    case tlExpose of
        InfixExpose val ->
            Pretty.string val
                |> Pretty.parens

        FunctionExpose val ->
            Pretty.string val

        TypeOrAliasExpose val ->
            Pretty.string val

        TypeExpose exposedType ->
            case exposedType.open of
                Nothing ->
                    Pretty.string exposedType.name

                Just _ ->
                    Pretty.string exposedType.name
                        |> Pretty.a (Pretty.string "(..)")



--== Declarations


{-| Pretty prints a single top-level declaration.
-}
prettyDeclaration : Int -> Declaration -> Doc
prettyDeclaration width decl =
    let
        innerDecl =
            prettyDocComment width decl
    in
    prettyElmSyntaxDeclaration innerDecl


{-| Pretty prints an elm-syntax declaration.
-}
prettyElmSyntaxDeclaration : Elm.Syntax.Declaration.Declaration -> Doc
prettyElmSyntaxDeclaration decl =
    case decl of
        Elm.Syntax.Declaration.FunctionDeclaration fn ->
            prettyFun fn

        Elm.Syntax.Declaration.AliasDeclaration tAlias ->
            prettyTypeAlias tAlias

        Elm.Syntax.Declaration.CustomTypeDeclaration type_ ->
            prettyCustomType type_

        Elm.Syntax.Declaration.PortDeclaration sig ->
            prettyPortDeclaration sig

        Elm.Syntax.Declaration.InfixDeclaration infix_ ->
            prettyInfix infix_

        Elm.Syntax.Declaration.Destructuring pattern expr ->
            prettyDestructuring (denode pattern) (denode expr)


prettyDeclarations : List Elm.Syntax.Declaration.Declaration -> Doc
prettyDeclarations decls =
    List.map
        (\decl ->
            prettyElmSyntaxDeclaration decl
                |> Pretty.a Pretty.line
        )
        decls
        |> doubleLines


{-| Pretty prints any doc comments on a declaration to string format, and provides
the result as an elm-syntax declaration.
-}
prettyDocComment : Int -> Declaration -> Elm.Syntax.Declaration.Declaration
prettyDocComment width decl =
    case decl of
        DeclWithComment comment declFn ->
            declFn (Elm.Comments.prettyDocComment width comment)

        DeclNoComment declNoComment ->
            declNoComment


{-| Pretty prints an Elm function, which may include documentation and a signature too.
-}
prettyFun : Function -> Doc
prettyFun fn =
    [ prettyMaybe prettyDocumentation (denodeMaybe fn.documentation)
    , prettyMaybe prettySignature (denodeMaybe fn.signature)
    , prettyFunctionImplementation (denode fn.declaration)
    ]
        |> Pretty.lines


{-| Pretty prints a type alias definition, which may include documentation too.
-}
prettyTypeAlias : TypeAlias -> Doc
prettyTypeAlias tAlias =
    let
        typeAliasPretty =
            [ Pretty.string "type alias"
            , Pretty.string (denode tAlias.name)
            , List.map Pretty.string (denodeAll tAlias.generics) |> Pretty.words
            , Pretty.string "="
            ]
                |> Pretty.words
                |> Pretty.a Pretty.line
                |> Pretty.a (prettyTypeAnnotation (denode tAlias.typeAnnotation))
                |> Pretty.nest 4
    in
    [ prettyMaybe prettyDocumentation (denodeMaybe tAlias.documentation)
    , typeAliasPretty
    ]
        |> Pretty.lines


{-| Pretty prints a custom type declaration, which may include documentation too.
-}
prettyCustomType : Type -> Doc
prettyCustomType type_ =
    let
        customTypePretty =
            [ Pretty.string "type"
            , Pretty.string (denode type_.name)
            , List.map Pretty.string (denodeAll type_.generics) |> Pretty.words
            ]
                |> Pretty.words
                |> Pretty.a Pretty.line
                |> Pretty.a (Pretty.string "= ")
                |> Pretty.a (prettyValueConstructors (denodeAll type_.constructors))
                |> Pretty.nest 4
    in
    [ prettyMaybe prettyDocumentation (denodeMaybe type_.documentation)
    , customTypePretty
    ]
        |> Pretty.lines


prettyValueConstructors : List ValueConstructor -> Doc
prettyValueConstructors constructors =
    List.map prettyValueConstructor constructors
        |> Pretty.join (Pretty.line |> Pretty.a (Pretty.string "| "))


prettyValueConstructor : ValueConstructor -> Doc
prettyValueConstructor cons =
    [ Pretty.string (denode cons.name)
    , List.map prettyTypeAnnotationParens (denodeAll cons.arguments) |> Pretty.lines
    ]
        |> Pretty.lines
        |> Pretty.group
        |> Pretty.nest 4


{-| Pretty prints a port declaration.
-}
prettyPortDeclaration : Signature -> Doc
prettyPortDeclaration sig =
    [ Pretty.string "port"
    , prettySignature sig
    ]
        |> Pretty.words


prettyInfix : Infix -> Doc
prettyInfix infix_ =
    let
        dirToString direction =
            case direction of
                Left ->
                    "left"

                Right ->
                    "right"

                Non ->
                    "non"
    in
    [ Pretty.string "infix"
    , Pretty.string (dirToString (denode infix_.direction))
    , Pretty.string (String.fromInt (denode infix_.precedence))
    , Pretty.string (denode infix_.operator) |> Pretty.parens
    , Pretty.string "="
    , Pretty.string (denode infix_.function)
    ]
        |> Pretty.words


{-| Pretty prints a desctructuring declaration.
-}
prettyDestructuring : Pattern -> Expression -> Doc
prettyDestructuring pattern expr =
    [ [ prettyPattern pattern
      , Pretty.string "="
      ]
        |> Pretty.words
    , prettyExpression expr
    ]
        |> Pretty.lines
        |> Pretty.nest 4


prettyDocumentation : Documentation -> Doc
prettyDocumentation docs =
    Pretty.string docs


{-| Pretty prints a type signature.
-}
prettySignature : Signature -> Doc
prettySignature sig =
    [ [ Pretty.string (denode sig.name)
      , Pretty.string ":"
      ]
        |> Pretty.words
    , prettyTypeAnnotation (denode sig.typeAnnotation)
    ]
        |> Pretty.lines
        |> Pretty.nest 4
        |> Pretty.group


prettyFunctionImplementation : FunctionImplementation -> Doc
prettyFunctionImplementation impl =
    Pretty.words
        [ Pretty.string (denode impl.name)
        , prettyArgs (denodeAll impl.arguments)
        , Pretty.string "="
        ]
        |> Pretty.a Pretty.line
        |> Pretty.a (prettyExpression (denode impl.expression))
        |> Pretty.nest 4


prettyArgs : List Pattern -> Doc
prettyArgs args =
    List.map (prettyPatternInner False) args
        |> Pretty.words



--== Patterns


{-| Pretty prints a pattern.
-}
prettyPattern : Pattern -> Doc
prettyPattern pattern =
    prettyPatternInner True pattern


adjustPatternParentheses : Bool -> Pattern -> Pattern
adjustPatternParentheses isTop pattern =
    let
        addParens pat =
            case ( isTop, pat ) of
                ( False, NamedPattern _ (_ :: _) ) ->
                    nodify pat |> ParenthesizedPattern

                ( False, AsPattern _ _ ) ->
                    nodify pat |> ParenthesizedPattern

                ( _, _ ) ->
                    pat

        removeParens pat =
            case pat of
                ParenthesizedPattern innerPat ->
                    if shouldRemove (denode innerPat) then
                        denode innerPat
                            |> removeParens

                    else
                        pat

                _ ->
                    pat

        shouldRemove pat =
            case ( isTop, pat ) of
                ( False, NamedPattern _ _ ) ->
                    False

                ( _, AsPattern _ _ ) ->
                    False

                ( _, _ ) ->
                    isTop
    in
    removeParens pattern
        |> addParens


prettyPatternInner : Bool -> Pattern -> Doc
prettyPatternInner isTop pattern =
    case adjustPatternParentheses isTop pattern of
        AllPattern ->
            Pretty.string "_"

        UnitPattern ->
            Pretty.string "()"

        CharPattern val ->
            Pretty.string (escapeChar val)
                |> singleQuotes

        StringPattern val ->
            Pretty.string val
                |> quotes

        IntPattern val ->
            Pretty.string (String.fromInt val)

        HexPattern val ->
            Pretty.string (Hex.toString val)

        FloatPattern val ->
            Pretty.string (String.fromFloat val)

        TuplePattern vals ->
            Pretty.space
                |> Pretty.a
                    (List.map (prettyPatternInner True) (denodeAll vals)
                        |> Pretty.join (Pretty.string ", ")
                    )
                |> Pretty.a Pretty.space
                |> Pretty.parens

        RecordPattern fields ->
            List.map Pretty.string (denodeAll fields)
                |> Pretty.join (Pretty.string ", ")
                |> Pretty.surround Pretty.space Pretty.space
                |> Pretty.braces

        UnConsPattern hdPat tlPat ->
            [ prettyPatternInner False (denode hdPat)
            , Pretty.string "::"
            , prettyPatternInner False (denode tlPat)
            ]
                |> Pretty.words

        ListPattern listPats ->
            case listPats of
                [] ->
                    Pretty.string "[]"

                _ ->
                    let
                        open =
                            Pretty.a Pretty.space (Pretty.string "[")

                        close =
                            Pretty.a (Pretty.string "]") Pretty.space
                    in
                    List.map (prettyPatternInner False) (denodeAll listPats)
                        |> Pretty.join (Pretty.string ", ")
                        |> Pretty.surround open close

        VarPattern var ->
            Pretty.string var

        NamedPattern qnRef listPats ->
            (prettyModuleNameDot qnRef.moduleName
                |> Pretty.a (Pretty.string qnRef.name)
            )
                :: List.map (prettyPatternInner False) (denodeAll listPats)
                |> Pretty.words

        AsPattern pat name ->
            [ prettyPatternInner False (denode pat)
            , Pretty.string "as"
            , Pretty.string (denode name)
            ]
                |> Pretty.words

        ParenthesizedPattern pat ->
            prettyPatternInner True (denode pat)
                |> Pretty.parens



--== Expressions


type alias Context =
    { precedence : Int
    , isTop : Bool
    , isLeftPipe : Bool
    }


topContext =
    { precedence = 11
    , isTop = True
    , isLeftPipe = False
    }


adjustExpressionParentheses : Context -> Expression -> Expression
adjustExpressionParentheses context expression =
    let
        addParens expr =
            case ( context.isTop, context.isLeftPipe, expr ) of
                ( False, False, LetExpression _ ) ->
                    nodify expr |> ParenthesizedExpression

                ( False, False, CaseExpression _ ) ->
                    nodify expr |> ParenthesizedExpression

                ( False, False, LambdaExpression _ ) ->
                    nodify expr |> ParenthesizedExpression

                ( False, False, IfBlock _ _ _ ) ->
                    nodify expr |> ParenthesizedExpression

                ( _, _, _ ) ->
                    expr

        removeParens expr =
            case expr of
                ParenthesizedExpression innerExpr ->
                    if shouldRemove (denode innerExpr) then
                        denode innerExpr
                            |> removeParens

                    else
                        expr

                _ ->
                    expr

        shouldRemove expr =
            case ( context.isTop, context.isLeftPipe, expr ) of
                ( True, _, _ ) ->
                    True

                ( _, True, _ ) ->
                    True

                ( False, _, Application _ ) ->
                    if context.precedence < 11 then
                        True

                    else
                        False

                ( False, _, FunctionOrValue _ _ ) ->
                    True

                ( False, _, Integer _ ) ->
                    True

                ( False, _, Hex _ ) ->
                    True

                ( False, _, Floatable _ ) ->
                    True

                ( False, _, Negation _ ) ->
                    True

                ( False, _, Literal _ ) ->
                    True

                ( False, _, CharLiteral _ ) ->
                    True

                ( False, _, TupledExpression _ ) ->
                    True

                ( False, _, RecordExpr _ ) ->
                    True

                ( False, _, ListExpr _ ) ->
                    True

                ( False, _, RecordAccess _ _ ) ->
                    True

                ( False, _, RecordAccessFunction _ ) ->
                    True

                ( False, _, RecordUpdateExpression _ _ ) ->
                    True

                ( _, _, _ ) ->
                    False
    in
    removeParens expression
        |> addParens


{-| Pretty prints an expression.
-}
prettyExpression : Expression -> Doc
prettyExpression expression =
    prettyExpressionInner topContext 4 expression
        |> Tuple.first


prettyExpressionInner : Context -> Int -> Expression -> ( Doc, Bool )
prettyExpressionInner context indent expression =
    case adjustExpressionParentheses context expression of
        UnitExpr ->
            ( Pretty.string "()"
            , False
            )

        Application exprs ->
            prettyApplication indent exprs

        OperatorApplication symbol dir exprl exprr ->
            prettyOperatorApplication indent symbol dir exprl exprr

        FunctionOrValue modl val ->
            ( prettyModuleNameDot modl
                |> Pretty.a (Pretty.string val)
            , False
            )

        IfBlock exprBool exprTrue exprFalse ->
            prettyIfBlock indent exprBool exprTrue exprFalse

        PrefixOperator symbol ->
            ( Pretty.string symbol |> Pretty.parens
            , False
            )

        Operator symbol ->
            ( Pretty.string symbol
            , False
            )

        Integer val ->
            ( Pretty.string (String.fromInt val)
            , False
            )

        Hex val ->
            ( Pretty.string (toHexString val)
            , False
            )

        Floatable val ->
            ( Pretty.string (String.fromFloat val)
            , False
            )

        Negation expr ->
            let
                ( prettyExpr, alwaysBreak ) =
                    prettyExpressionInner topContext 4 (denode expr)
            in
            ( Pretty.string "-"
                |> Pretty.a prettyExpr
            , alwaysBreak
            )

        Literal val ->
            ( prettyLiteral val
            , False
            )

        CharLiteral val ->
            ( Pretty.string (escapeChar val)
                |> singleQuotes
            , False
            )

        TupledExpression exprs ->
            prettyTupledExpression indent exprs

        ParenthesizedExpression expr ->
            prettyParenthesizedExpression indent expr

        LetExpression letBlock ->
            prettyLetBlock indent letBlock

        CaseExpression caseBlock ->
            prettyCaseBlock indent caseBlock

        LambdaExpression lambda ->
            prettyLambdaExpression indent lambda

        RecordExpr setters ->
            prettyRecordExpr setters

        ListExpr exprs ->
            prettyList indent exprs

        RecordAccess expr field ->
            prettyRecordAccess expr field

        RecordAccessFunction field ->
            ( Pretty.string field
            , False
            )

        RecordUpdateExpression var setters ->
            prettyRecordUpdateExpression indent var setters

        GLSLExpression val ->
            ( Pretty.string "glsl"
            , True
            )


prettyApplication : Int -> List (Node Expression) -> ( Doc, Bool )
prettyApplication indent exprs =
    let
        ( prettyExpressions, alwaysBreak ) =
            List.map (prettyExpressionInner { precedence = 11, isTop = False, isLeftPipe = False } 4) (denodeAll exprs)
                |> List.unzip
                |> Tuple.mapSecond Bool.Extra.any
    in
    ( prettyExpressions
        |> Pretty.lines
        |> Pretty.nest indent
        |> Pretty.align
        |> optionalGroup alwaysBreak
    , alwaysBreak
    )


isEndLineOperator : String -> Bool
isEndLineOperator op =
    case op of
        "<|" ->
            True

        _ ->
            False


prettyOperatorApplication : Int -> String -> InfixDirection -> Node Expression -> Node Expression -> ( Doc, Bool )
prettyOperatorApplication indent symbol dir exprl exprr =
    if symbol == "<|" then
        prettyOperatorApplicationLeft indent symbol dir exprl exprr

    else
        prettyOperatorApplicationRight indent symbol dir exprl exprr


prettyOperatorApplicationLeft : Int -> String -> InfixDirection -> Node Expression -> Node Expression -> ( Doc, Bool )
prettyOperatorApplicationLeft indent symbol _ exprl exprr =
    let
        context =
            { precedence = precedence symbol
            , isTop = False
            , isLeftPipe = True
            }

        ( prettyExpressionLeft, alwaysBreakLeft ) =
            prettyExpressionInner context 4 (denode exprl)

        ( prettyExpressionRight, alwaysBreakRight ) =
            prettyExpressionInner context 4 (denode exprr)

        alwaysBreak =
            alwaysBreakLeft || alwaysBreakRight
    in
    ( [ [ prettyExpressionLeft, Pretty.string symbol ] |> Pretty.words
      , prettyExpressionRight
      ]
        |> Pretty.lines
        |> optionalGroup alwaysBreak
        |> Pretty.nest 4
    , alwaysBreak
    )


prettyOperatorApplicationRight : Int -> String -> InfixDirection -> Node Expression -> Node Expression -> ( Doc, Bool )
prettyOperatorApplicationRight indent symbol _ exprl exprr =
    let
        expandExpr : Int -> Context -> Expression -> List ( Doc, Bool )
        expandExpr innerIndent context expr =
            case expr of
                OperatorApplication sym _ left right ->
                    innerOpApply False sym left right

                _ ->
                    [ prettyExpressionInner context innerIndent expr ]

        innerOpApply : Bool -> String -> Node Expression -> Node Expression -> List ( Doc, Bool )
        innerOpApply isTop sym left right =
            let
                context =
                    { precedence = precedence sym
                    , isTop = False
                    , isLeftPipe = "<|" == sym
                    }

                innerIndent =
                    decrementIndent 4 (String.length symbol + 1)

                leftIndent =
                    if isTop then
                        indent

                    else
                        innerIndent

                rightSide =
                    denode right |> expandExpr innerIndent context
            in
            case rightSide of
                ( hdExpr, hdBreak ) :: tl ->
                    List.append (denode left |> expandExpr leftIndent context)
                        (( Pretty.string sym |> Pretty.a Pretty.space |> Pretty.a hdExpr, hdBreak ) :: tl)

                [] ->
                    []

        ( prettyExpressions, alwaysBreak ) =
            innerOpApply True symbol exprl exprr
                |> List.unzip
                |> Tuple.mapSecond Bool.Extra.any
    in
    ( prettyExpressions
        |> Pretty.join (Pretty.nest indent Pretty.line)
        |> Pretty.align
        |> optionalGroup alwaysBreak
    , alwaysBreak
    )


prettyIfBlock : Int -> Node Expression -> Node Expression -> Node Expression -> ( Doc, Bool )
prettyIfBlock indent exprBool exprTrue exprFalse =
    let
        innerIfBlock : Node Expression -> Node Expression -> Node Expression -> List Doc
        innerIfBlock innerExprBool innerExprTrue innerExprFalse =
            let
                context =
                    topContext

                ifPart =
                    let
                        ( prettyBoolExpr, alwaysBreak ) =
                            prettyExpressionInner topContext 4 (denode innerExprBool)
                    in
                    [ [ Pretty.string "if"
                      , prettyExpressionInner topContext 4 (denode innerExprBool) |> Tuple.first
                      ]
                        |> Pretty.lines
                        |> optionalGroup alwaysBreak
                        |> Pretty.nest indent
                    , Pretty.string "then"
                    ]
                        |> Pretty.lines
                        |> optionalGroup alwaysBreak

                truePart =
                    prettyExpressionInner topContext 4 (denode innerExprTrue)
                        |> Tuple.first
                        |> Pretty.indent indent

                elsePart =
                    Pretty.line
                        |> Pretty.a (Pretty.string "else")

                falsePart =
                    case denode innerExprFalse of
                        IfBlock nestedExprBool nestedExprTrue nestedExprFalse ->
                            innerIfBlock nestedExprBool nestedExprTrue nestedExprFalse

                        _ ->
                            [ prettyExpressionInner topContext 4 (denode innerExprFalse)
                                |> Tuple.first
                                |> Pretty.indent indent
                            ]
            in
            case falsePart of
                [] ->
                    []

                [ falseExpr ] ->
                    [ ifPart
                    , truePart
                    , elsePart
                    , falseExpr
                    ]

                hd :: tl ->
                    List.append
                        [ ifPart
                        , truePart
                        , [ elsePart, hd ] |> Pretty.words
                        ]
                        tl

        prettyExpressions =
            innerIfBlock exprBool exprTrue exprFalse
    in
    ( prettyExpressions
        |> Pretty.lines
        |> Pretty.align
    , True
    )


prettyLiteral : String -> Doc
prettyLiteral val =
    Pretty.string (escape val)
        |> quotes


prettyTupledExpression : Int -> List (Node Expression) -> ( Doc, Bool )
prettyTupledExpression indent exprs =
    let
        open =
            Pretty.a Pretty.space (Pretty.string "(")

        close =
            Pretty.a (Pretty.string ")") Pretty.line
    in
    case exprs of
        [] ->
            ( Pretty.string "()", False )

        _ ->
            let
                ( prettyExpressions, alwaysBreak ) =
                    List.map (prettyExpressionInner topContext (decrementIndent indent 2)) (denodeAll exprs)
                        |> List.unzip
                        |> Tuple.mapSecond Bool.Extra.any
            in
            ( prettyExpressions
                |> Pretty.separators ", "
                |> Pretty.surround open close
                |> Pretty.align
                |> optionalGroup alwaysBreak
            , alwaysBreak
            )


prettyParenthesizedExpression : Int -> Node Expression -> ( Doc, Bool )
prettyParenthesizedExpression indent expr =
    let
        open =
            Pretty.string "("

        close =
            Pretty.a (Pretty.string ")") Pretty.tightline

        ( prettyExpr, alwaysBreak ) =
            prettyExpressionInner topContext (decrementIndent indent 1) (denode expr)
    in
    ( prettyExpr
        |> Pretty.nest 1
        |> Pretty.surround open close
        |> Pretty.align
        |> optionalGroup alwaysBreak
    , alwaysBreak
    )


prettyLetBlock : Int -> LetBlock -> ( Doc, Bool )
prettyLetBlock indent letBlock =
    ( [ Pretty.string "let"
      , List.map (prettyLetDeclaration indent) (denodeAll letBlock.declarations)
            |> doubleLines
            |> Pretty.indent indent
      , Pretty.string "in"
      , prettyExpressionInner topContext 4 (denode letBlock.expression) |> Tuple.first
      ]
        |> Pretty.lines
        |> Pretty.align
    , True
    )


prettyLetDeclaration : Int -> LetDeclaration -> Doc
prettyLetDeclaration indent letDecl =
    case letDecl of
        LetFunction fn ->
            prettyFun fn

        LetDestructuring pattern expr ->
            [ prettyPatternInner False (denode pattern)
            , Pretty.string "="
            ]
                |> Pretty.words
                |> Pretty.a Pretty.line
                |> Pretty.a
                    (prettyExpressionInner topContext 4 (denode expr)
                        |> Tuple.first
                        |> Pretty.indent indent
                    )


prettyCaseBlock : Int -> CaseBlock -> ( Doc, Bool )
prettyCaseBlock indent caseBlock =
    let
        casePart =
            let
                ( caseExpression, alwaysBreak ) =
                    prettyExpressionInner topContext 4 (denode caseBlock.expression)
            in
            [ [ Pretty.string "case"
              , caseExpression
              ]
                |> Pretty.lines
                |> optionalGroup alwaysBreak
                |> Pretty.nest indent
            , Pretty.string "of"
            ]
                |> Pretty.lines
                |> optionalGroup alwaysBreak

        prettyCase ( pattern, expr ) =
            prettyPattern (denode pattern)
                |> Pretty.a (Pretty.string " ->")
                |> Pretty.a Pretty.line
                |> Pretty.a (prettyExpressionInner topContext 4 (denode expr) |> Tuple.first |> Pretty.indent 4)
                |> Pretty.indent indent

        patternsPart =
            List.map prettyCase caseBlock.cases
                |> doubleLines
    in
    ( [ casePart, patternsPart ]
        |> Pretty.lines
        |> Pretty.align
    , True
    )


prettyLambdaExpression : Int -> Lambda -> ( Doc, Bool )
prettyLambdaExpression indent lambda =
    let
        ( prettyExpr, alwaysBreak ) =
            prettyExpressionInner topContext 4 (denode lambda.expression)
    in
    ( [ Pretty.string "\\"
            |> Pretty.a (List.map (prettyPatternInner False) (denodeAll lambda.args) |> Pretty.words)
            |> Pretty.a (Pretty.string " ->")
      , prettyExpr
      ]
        |> Pretty.lines
        |> Pretty.nest indent
        |> Pretty.align
        |> optionalGroup alwaysBreak
    , alwaysBreak
    )


prettyRecordExpr : List (Node RecordSetter) -> ( Doc, Bool )
prettyRecordExpr setters =
    let
        open =
            Pretty.a Pretty.space (Pretty.string "{")

        close =
            Pretty.a (Pretty.string "}")
                Pretty.line
    in
    case setters of
        [] ->
            ( Pretty.string "{}", False )

        _ ->
            let
                ( prettyExpressions, alwaysBreak ) =
                    List.map prettySetter (denodeAll setters)
                        |> List.unzip
                        |> Tuple.mapSecond Bool.Extra.any
            in
            ( prettyExpressions
                |> Pretty.separators ", "
                |> Pretty.surround open close
                |> Pretty.align
                |> optionalGroup alwaysBreak
            , alwaysBreak
            )


prettySetter : ( Node String, Node Expression ) -> ( Doc, Bool )
prettySetter ( fld, val ) =
    let
        ( prettyExpr, alwaysBreak ) =
            prettyExpressionInner topContext 4 (denode val)
    in
    ( [ [ Pretty.string (denode fld)
        , Pretty.string "="
        ]
            |> Pretty.words
      , prettyExpr
      ]
        |> Pretty.lines
        |> optionalGroup alwaysBreak
        |> Pretty.nest 4
    , alwaysBreak
    )


prettyList : Int -> List (Node Expression) -> ( Doc, Bool )
prettyList indent exprs =
    let
        open =
            Pretty.a Pretty.space (Pretty.string "[")

        close =
            Pretty.a (Pretty.string "]") Pretty.line
    in
    case exprs of
        [] ->
            ( Pretty.string "[]", False )

        _ ->
            let
                ( prettyExpressions, alwaysBreak ) =
                    List.map (prettyExpressionInner topContext (decrementIndent indent 2)) (denodeAll exprs)
                        |> List.unzip
                        |> Tuple.mapSecond Bool.Extra.any
            in
            ( prettyExpressions
                |> Pretty.separators ", "
                |> Pretty.surround open close
                |> Pretty.align
                |> optionalGroup alwaysBreak
            , alwaysBreak
            )


prettyRecordAccess : Node Expression -> Node String -> ( Doc, Bool )
prettyRecordAccess expr field =
    let
        ( prettyExpr, alwaysBreak ) =
            prettyExpressionInner topContext 4 (denode expr)
    in
    ( prettyExpr
        |> Pretty.a dot
        |> Pretty.a (Pretty.string (denode field))
    , alwaysBreak
    )


prettyRecordUpdateExpression : Int -> Node String -> List (Node RecordSetter) -> ( Doc, Bool )
prettyRecordUpdateExpression indent var setters =
    let
        open =
            [ Pretty.string "{"
            , Pretty.string (denode var)
            ]
                |> Pretty.words
                |> Pretty.a Pretty.line

        close =
            Pretty.a (Pretty.string "}")
                Pretty.line

        addBarToFirst exprs =
            case exprs of
                [] ->
                    []

                hd :: tl ->
                    Pretty.a hd (Pretty.string "| ") :: tl
    in
    case setters of
        [] ->
            ( Pretty.string "{}", False )

        _ ->
            let
                ( prettyExpressions, alwaysBreak ) =
                    List.map prettySetter (denodeAll setters)
                        |> List.unzip
                        |> Tuple.mapSecond Bool.Extra.any
            in
            ( open
                |> Pretty.a
                    (prettyExpressions
                        |> addBarToFirst
                        |> Pretty.separators ", "
                    )
                |> Pretty.nest indent
                |> Pretty.surround Pretty.empty close
                |> Pretty.align
                |> optionalGroup alwaysBreak
            , alwaysBreak
            )



--== Type Annotations


{-| Pretty prints a type annotation.
-}
prettyTypeAnnotation : TypeAnnotation -> Doc
prettyTypeAnnotation typeAnn =
    case typeAnn of
        GenericType val ->
            Pretty.string val

        Typed fqName anns ->
            prettyTyped fqName anns

        Unit ->
            Pretty.string "()"

        Tupled anns ->
            prettyTupled anns

        Record recordDef ->
            prettyRecord (denodeAll recordDef)

        GenericRecord paramName recordDef ->
            prettyGenericRecord (denode paramName) (denodeAll (denode recordDef))

        FunctionTypeAnnotation fromAnn toAnn ->
            prettyFunctionTypeAnnotation fromAnn toAnn


prettyTyped : Node ( ModuleName, String ) -> List (Node TypeAnnotation) -> Doc
prettyTyped fqName anns =
    let
        ( moduleName, typeName ) =
            denode fqName

        typeDoc =
            prettyModuleNameDot moduleName
                |> Pretty.a (Pretty.string typeName)

        argsDoc =
            List.map prettyTypeAnnotationParens (denodeAll anns)
                |> Pretty.words
    in
    [ typeDoc
    , argsDoc
    ]
        |> Pretty.words


prettyTupled : List (Node TypeAnnotation) -> Doc
prettyTupled anns =
    Pretty.space
        |> Pretty.a
            (List.map prettyTypeAnnotation (denodeAll anns)
                |> Pretty.join (Pretty.string ", ")
            )
        |> Pretty.a Pretty.space
        |> Pretty.parens


prettyTypeAnnotationParens : TypeAnnotation -> Doc
prettyTypeAnnotationParens typeAnn =
    if isNakedCompound typeAnn then
        prettyTypeAnnotation typeAnn |> Pretty.parens

    else
        prettyTypeAnnotation typeAnn


prettyRecord : List RecordField -> Doc
prettyRecord fields =
    let
        open =
            Pretty.a Pretty.space (Pretty.string "{")

        close =
            Pretty.a (Pretty.string "}") Pretty.line
    in
    case fields of
        [] ->
            Pretty.string "{}"

        _ ->
            fields
                |> List.map (Tuple.mapBoth denode denode)
                |> List.map prettyFieldTypeAnn
                |> Pretty.separators ", "
                |> Pretty.surround open close
                |> Pretty.group


prettyGenericRecord : String -> List RecordField -> Doc
prettyGenericRecord paramName fields =
    let
        open =
            [ Pretty.string "{"
            , Pretty.string paramName
            ]
                |> Pretty.words
                |> Pretty.a Pretty.line

        close =
            Pretty.a (Pretty.string "}")
                Pretty.line

        addBarToFirst exprs =
            case exprs of
                [] ->
                    []

                hd :: tl ->
                    Pretty.a hd (Pretty.string "| ") :: tl
    in
    case fields of
        [] ->
            Pretty.string "{}"

        _ ->
            open
                |> Pretty.a
                    (fields
                        |> List.map (Tuple.mapBoth denode denode)
                        |> List.map prettyFieldTypeAnn
                        |> addBarToFirst
                        |> Pretty.separators ", "
                    )
                |> Pretty.nest 4
                |> Pretty.surround Pretty.empty close
                |> Pretty.group


prettyFieldTypeAnn : ( String, TypeAnnotation ) -> Doc
prettyFieldTypeAnn ( name, ann ) =
    [ [ Pretty.string name
      , Pretty.string ":"
      ]
        |> Pretty.words
    , prettyTypeAnnotation ann
    ]
        |> Pretty.lines
        |> Pretty.nest 4
        |> Pretty.group


prettyFunctionTypeAnnotation : Node TypeAnnotation -> Node TypeAnnotation -> Doc
prettyFunctionTypeAnnotation left right =
    let
        expandLeft : TypeAnnotation -> Doc
        expandLeft ann =
            case ann of
                FunctionTypeAnnotation _ _ ->
                    prettyTypeAnnotationParens ann

                _ ->
                    prettyTypeAnnotation ann

        expandRight : TypeAnnotation -> List Doc
        expandRight ann =
            case ann of
                FunctionTypeAnnotation innerLeft innerRight ->
                    innerFnTypeAnn innerLeft innerRight

                _ ->
                    [ prettyTypeAnnotation ann ]

        innerFnTypeAnn : Node TypeAnnotation -> Node TypeAnnotation -> List Doc
        innerFnTypeAnn innerLeft innerRight =
            let
                rightSide =
                    denode innerRight |> expandRight
            in
            case rightSide of
                hd :: tl ->
                    (denode innerLeft |> expandLeft)
                        :: ([ Pretty.string "->", hd ] |> Pretty.words)
                        :: tl

                [] ->
                    []
    in
    innerFnTypeAnn left right
        |> Pretty.lines
        |> Pretty.group


{-| A type annotation is a naked compound if it is made up of multiple parts that
are not enclosed in brackets or braces. This means either a type or type alias with
arguments or a function type; records and tuples are compound but enclosed in brackets
or braces.

Naked type annotations need to be bracketed in situations type argument bindings are
ambiguous otherwise.

-}
isNakedCompound : TypeAnnotation -> Bool
isNakedCompound typeAnn =
    case typeAnn of
        Typed _ [] ->
            False

        Typed _ args ->
            True

        FunctionTypeAnnotation _ _ ->
            True

        _ ->
            False



--== Helpers


prettyMaybe : (a -> Doc) -> Maybe a -> Doc
prettyMaybe prettyFn maybeVal =
    Maybe.map prettyFn maybeVal
        |> Maybe.withDefault Pretty.empty


decrementIndent : Int -> Int -> Int
decrementIndent currentIndent spaces =
    let
        modded =
            modBy 4 (currentIndent - spaces)
    in
    if modded == 0 then
        4

    else
        modded


dot : Doc
dot =
    Pretty.string "."


quotes : Doc -> Doc
quotes doc =
    Pretty.surround (Pretty.char '"') (Pretty.char '"') doc


tripleQuotes : Doc -> Doc
tripleQuotes doc =
    Pretty.surround (Pretty.string "\"\"\"") (Pretty.string "\"\"\"") doc


singleQuotes : Doc -> Doc
singleQuotes doc =
    Pretty.surround (Pretty.char '\'') (Pretty.char '\'') doc


sqParens : Doc -> Doc
sqParens doc =
    Pretty.surround (Pretty.string "[") (Pretty.string "]") doc


doubleLines : List Doc -> Doc
doubleLines =
    Pretty.join (Pretty.a Pretty.line Pretty.line)


escape : String -> String
escape val =
    val
        |> String.replace "\\" "\\\\"
        |> String.replace "\"" "\\\""
        |> String.replace "\n" "\\n"
        |> String.replace "\t" "\\t"


escapeChar : Char -> String
escapeChar val =
    case val of
        '\'' ->
            "\\'"

        c ->
            String.fromChar c


optionalGroup : Bool -> Doc -> Doc
optionalGroup flag doc =
    if flag then
        doc

    else
        Pretty.group doc


optionalParens : Bool -> Doc -> Doc
optionalParens flag doc =
    if flag then
        Pretty.parens doc

    else
        doc


toHexString : Int -> String
toHexString val =
    let
        padWithZeros str =
            let
                length =
                    String.length str
            in
            if length < 2 then
                String.padLeft 2 '0' str

            else if length > 2 && length < 4 then
                String.padLeft 4 '0' str

            else if length > 4 && length < 8 then
                String.padLeft 8 '0' str

            else
                str
    in
    "0x" ++ (Hex.toString val |> String.toUpper |> padWithZeros)


{-| Calculate a precedence for any operator to be able to know when
parenthesis are needed or not.

When a lower precedence expression appears beneath a higher one, its needs
parenthesis.

When a higher precedence expression appears beneath a lower one, if should
not have parenthesis.

-}
precedence : String -> Int
precedence symbol =
    case symbol of
        ">>" ->
            9

        "<<" ->
            9

        "^" ->
            8

        "*" ->
            7

        "/" ->
            7

        "//" ->
            7

        "%" ->
            7

        "rem" ->
            7

        "+" ->
            6

        "-" ->
            6

        "++" ->
            5

        "::" ->
            5

        "==" ->
            4

        "/=" ->
            4

        "<" ->
            4

        ">" ->
            4

        "<=" ->
            4

        ">=" ->
            4

        "&&" ->
            3

        "||" ->
            2

        "|>" ->
            0

        "<|" ->
            0

        _ ->
            0
