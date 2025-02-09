module Ren.Compiler.Parse exposing (run)

{-|

@docs run

-}

-- IMPORTS ---------------------------------------------------------------------

import Data.Either
import Dict
import Parser.Advanced as Parser exposing ((|.), (|=))
import Pratt.Advanced as Pratt
import Ren.AST.Expr as Expr exposing (Expr(..), ExprF(..))
import Ren.AST.Module as Module exposing (ImportSpecifier(..), Module)
import Ren.Compiler.Error as Error exposing (Error)
import Ren.Compiler.Parse.Util as Util
import Ren.Data.Span as Span exposing (Span)
import Ren.Data.Type as Type exposing (Type)
import Set exposing (Set)


{-| -}
run : String -> String -> Result Error (Module Span)
run name_ input =
    Parser.run (module_ name_) input
        |> Result.mapError Error.ParseError



-- TYPES -----------------------------------------------------------------------


{-| -}
type alias Parser a =
    Parser.Parser Error.ParseContext Error.ParseError a


{-| -}
type alias Config a =
    Pratt.Config Error.ParseContext Error.ParseError a



--                                                                            --
-- MODULE PARSERS --------------------------------------------------------------
--                                                                            --


{-| -}
module_ : String -> Parser (Module Span)
module_ name_ =
    Parser.succeed (Module name_)
        |. Util.ignorables (Parser.Token "//" <| Error.expectingSymbol "//")
        |= Parser.loop []
            (\imports ->
                Parser.oneOf
                    [ Parser.succeed (\i -> i :: imports)
                        |. Util.ignorables (Parser.Token "//" <| Error.expectingSymbol "//")
                        |= import_
                        |. Util.ignorables (Parser.Token "//" <| Error.expectingSymbol "//")
                        |> Parser.map Parser.Loop
                    , Parser.succeed ()
                        |> Parser.map (\_ -> List.reverse imports)
                        |> Parser.map Parser.Done
                    ]
            )
        |. Util.whitespace
        |= Parser.loop []
            (\declarations ->
                Parser.oneOf
                    [ Parser.succeed (\d -> d :: declarations)
                        |. Util.ignorables (Parser.Token "//" <| Error.expectingSymbol "//")
                        |= declaration
                        |. Util.ignorables (Parser.Token "//" <| Error.expectingSymbol "//")
                        |> Parser.map Parser.Loop
                    , Parser.succeed ()
                        |> Parser.map (\_ -> List.reverse declarations)
                        |> Parser.map Parser.Done
                    ]
            )
        |. Util.whitespace
        |. Parser.end Error.expectingEOF


{-| -}
importSpecifier : Parser Module.ImportSpecifier
importSpecifier =
    let
        path =
            Parser.succeed Basics.identity
                -- TODO: This doesn't handle escaped `"` characters.
                |. symbol "\""
                |= (Parser.getChompedString <| Parser.chompWhile ((/=) '"'))
                |. symbol "\""
    in
    Parser.oneOf
        [ Parser.succeed ExternalImport
            |. keyword "ext"
            |. Util.whitespace
            |= path
        , Parser.succeed PackageImport
            |. keyword "pkg"
            |. Util.whitespace
            |= path
        , Parser.succeed LocalImport
            |= path
        ]


{-| -}
import_ : Parser Module.Import
import_ =
    Parser.succeed Module.Import
        |. keyword "import"
        |. Util.whitespace
        |= importSpecifier
        |. Util.whitespace
        |= Parser.oneOf
            [ Parser.succeed Basics.identity
                |. keyword "as"
                |. Util.whitespace
                |= Parser.loop []
                    (\names ->
                        Parser.oneOf
                            [ Parser.succeed (\n -> n :: names)
                                |= uppercaseName Set.empty
                                |. symbol "."
                                |> Parser.map Parser.Loop
                                |> Parser.backtrackable
                            , Parser.succeed (\n -> n :: names)
                                |= uppercaseName Set.empty
                                |> Parser.map (Parser.Done << List.reverse)
                            , Parser.succeed ()
                                |> Parser.map (\_ -> List.reverse names)
                                |> Parser.map Parser.Done
                            ]
                    )
            , Parser.succeed []
            ]
        |. Util.whitespace
        |= Parser.oneOf
            [ Parser.succeed Basics.identity
                |. keyword "exposing"
                |. Util.whitespace
                |= Parser.sequence
                    { start = Parser.Token "{" (Error.expectingSymbol "{")
                    , separator = Parser.Token "," (Error.expectingSymbol ",")
                    , end = Parser.Token "}" (Error.expectingSymbol "}")
                    , spaces = Util.whitespace
                    , item = lowercaseName keywords
                    , trailing = Parser.Forbidden
                    }
                |> Parser.backtrackable
            , Parser.succeed []
            ]
        |> Parser.inContext Error.InImport



--                                                                            --
-- EXPRESSION PARSERS ----------------------------------------------------------
--                                                                            --


{-| -}
declaration : Parser (Module.Declaration Span)
declaration =
    Parser.oneOf
        [ run_
        , ext
        , let_
        , typedef
        ]


run_ : Parser (Module.Declaration Span)
run_ =
    Parser.succeed Module.Run
        |. keyword "run"
        |. Parser.commit ()
        |= expression
        |> Span.parser (|>)
        |> Parser.inContext Error.InDeclaration


ext : Parser (Module.Declaration Span)
ext =
    Parser.succeed Module.Ext
        |= Parser.oneOf
            [ Parser.succeed True
                |. keyword "pub"
            , Parser.succeed False
            ]
        |. Util.whitespace
        |. keyword "ext"
        |. Parser.commit ()
        |. Util.whitespace
        |= lowercaseName keywords
        |. Util.whitespace
        |= Parser.oneOf
            [ Parser.succeed Basics.identity
                |. symbol ":"
                |. Util.whitespace
                |= type_
                |. Util.whitespace
            , Parser.succeed Type.Any
            ]
        |> Span.parser (|>)
        |> Parser.inContext Error.InDeclaration
        |> Parser.backtrackable


let_ : Parser (Module.Declaration Span)
let_ =
    Parser.succeed Module.Let
        |= Parser.oneOf
            [ Parser.succeed True
                |. keyword "pub"
            , Parser.succeed False
            ]
        |. Util.whitespace
        |. keyword "let"
        |. Util.whitespace
        |= lowercaseName keywords
        |. Util.whitespace
        |= Parser.oneOf
            [ Parser.succeed Basics.identity
                |. symbol ":"
                |. Util.whitespace
                |= type_
                |. Util.whitespace
            , Parser.succeed Type.Any
            ]
        |. symbol "="
        |. Util.whitespace
        |= expression
        |> Span.parser (|>)
        |> Parser.inContext Error.InDeclaration


typedef : Parser (Module.Declaration Span)
typedef =
    Parser.succeed Module.Type
        |= Parser.oneOf
            [ Parser.succeed True
                |. keyword "pub"
            , Parser.succeed False
            ]
        |. Util.whitespace
        |. keyword "type"
        |. Util.whitespace
        |= uppercaseName types
        |. Util.whitespace
        |= Parser.loop []
            (\tvars ->
                Parser.oneOf
                    [ Parser.succeed (\tvar -> tvar :: tvars)
                        |= lowercaseName Set.empty
                        |. Util.whitespace
                        |> Parser.map Parser.Loop
                    , Parser.succeed ()
                        |> Parser.map (\_ -> List.reverse tvars)
                        |> Parser.map Parser.Done
                    ]
            )
        |. Util.whitespace
        |> Parser.andThen
            (\f ->
                Parser.oneOf
                    [ Parser.succeed (\first rest -> f <| Module.Enum <| Dict.fromList (first :: rest))
                        |. symbol "="
                        |. Util.whitespace
                        |= variantT
                        |. Parser.commit ()
                        |= Parser.loop []
                            (\variants ->
                                Parser.oneOf
                                    [ Parser.succeed (\( tag, params ) -> ( tag, params ) :: variants)
                                        |. Util.whitespace
                                        |. symbol "|"
                                        |. Util.whitespace
                                        |= variantT
                                        |> Parser.map Parser.Loop
                                    , Parser.succeed ()
                                        |> Parser.map (\_ -> List.reverse variants)
                                        |> Parser.map Parser.Done
                                    ]
                            )
                        |> Parser.backtrackable
                    , Parser.succeed (\fields -> f <| Module.Record <| Dict.fromList fields)
                        |. symbol "="
                        |. Util.whitespace
                        |. symbol "{"
                        |. Parser.commit ()
                        |= Parser.sequence
                            { start = Parser.Token "" (Error.expectingSymbol "")
                            , separator = Parser.Token "," (Error.expectingSymbol ",")
                            , end = Parser.Token "}" (Error.expectingSymbol "}")
                            , spaces = Util.whitespace
                            , item =
                                Parser.succeed Tuple.pair
                                    |= lowercaseName keywords
                                    |. Util.whitespace
                                    |. symbol ":"
                                    |. Util.whitespace
                                    |= Parser.lazy (\_ -> type_)
                            , trailing = Parser.Forbidden
                            }
                    , Parser.succeed (f Module.Abstract)
                    ]
            )
        |> Span.parser (|>)



--                                                                            --
-- EXPRESSION PARSERS ----------------------------------------------------------
--                                                                            --


{-| -}
expression : Parser (Expr Span)
expression =
    prattExpression
        -- These parsers start with a keyword
        [ conditional
        , match

        -- These parsers parse sub expressions
        , Pratt.literal annotation
        , lambda
        , application
        , Pratt.literal access

        --
        , Pratt.literal identifier

        -- Subexpressions are wrapped in parentheses.
        , Pratt.literal (Parser.lazy (\_ -> subexpression))

        -- Blocks and record literals can both begin with a `{`. I'm not sure it
        -- matters which one we try first, though.
        , block
        , literal
        ]


{-| -}
prattExpression : List (Config (Expr Span) -> Parser (Expr Span)) -> Parser (Expr Span)
prattExpression parsers =
    Pratt.expression
        { oneOf = parsers
        , andThenOneOf =
            let
                -- This cursed dummy Span is necessary because we need the
                -- type of the infix expression to be the same as its sub-expressions
                -- but we can't get the Span start/end of the parser until
                -- we've created the parser...
                --
                -- It's cursed but it works.
                dummySpan =
                    Span.fromTuples ( 0, 0 ) ( 0, 0 )

                -- Helper parser for handling infix operator parsing. Takes the
                -- required symbol as a string helpfully wraps it up in a the
                -- `Parser.symbol` parser.
                infix_ parser precedence sym op =
                    Tuple.mapSecond locateInfix
                        << parser precedence
                            (operator sym)
                            (\lhs rhs -> Expr.wrap dummySpan (Infix op lhs rhs))

                -- This annotates a parsed infix expression with start/end Span
                -- data by taking the start of the left operand and the end of
                -- the right one.
                --
                -- Of course, we have to pattern match on the parsed expression
                -- even though we know it will be an Infix one, so we throw an
                -- internal error if somehow things go wrong.
                locateInfix parser expr =
                    Parser.andThen
                        (\(Expr _ e) ->
                            case e of
                                Infix _ (Expr { start } _) (Expr { end } _) ->
                                    Expr (Span start end) e
                                        |> Parser.succeed

                                _ ->
                                    Error.internalParseError "Parsed something other than an `Infix` expression in `andThenOneOf`"
                                        |> Parser.problem
                        )
                        (parser expr)
            in
            [ infix_ Pratt.infixLeft 1 "|>" Expr.Pipe
            , infix_ Pratt.infixRight 9 ">>" Expr.Compose
            , infix_ Pratt.infixLeft 4 "==" Expr.Eq
            , infix_ Pratt.infixLeft 4 "!=" Expr.NotEq
            , infix_ Pratt.infixLeft 4 "<=" Expr.Lte
            , infix_ Pratt.infixLeft 4 ">=" Expr.Lte
            , infix_ Pratt.infixRight 3 "&&" Expr.And
            , infix_ Pratt.infixRight 2 "||" Expr.Or
            , infix_ Pratt.infixRight 5 "::" Expr.Cons
            , infix_ Pratt.infixRight 5 "++" Expr.Join

            -- ONE CHARACTER OPERATORS
            , infix_ Pratt.infixLeft 4 "<" Expr.Lt
            , infix_ Pratt.infixLeft 4 ">" Expr.Gt
            , infix_ Pratt.infixLeft 6 "+" Expr.Add
            , infix_ Pratt.infixLeft 6 "-" Expr.Sub
            , infix_ Pratt.infixLeft 7 "*" Expr.Mul
            , infix_ Pratt.infixRight 7 "^" Expr.Pow
            , infix_ Pratt.infixRight 7 "%" Expr.Mod
            ]
        , spaces = Util.ignorables (Parser.Token "//" <| Error.expectingSymbol "//")
        }
        |> Parser.inContext Error.InExpr


{-| -}
subexpression : Parser (Expr Span)
subexpression =
    Parser.succeed identity
        |. symbol "("
        |. Util.whitespace
        |= expression
        |. Util.whitespace
        |. symbol ")"


{-| -}
parenthesised : Parser (Expr Span)
parenthesised =
    Parser.oneOf
        [ -- These are all the expressions that can be unambiguously parsed
          -- without parentheses in contexts where parentheses might be necessary.
          Pratt.expression
            { oneOf =
                [ block
                , \config ->
                    Parser.succeed Literal
                        |= Parser.oneOf
                            [ array config
                            , boolean
                            , number
                            , record config
                            , string
                            , template config
                            , undefined
                            ]
                        |> Span.parser Expr
                , Pratt.literal identifier
                ]
            , andThenOneOf = []
            , spaces = Util.ignorables (Parser.Token "//" <| Error.expectingSymbol "//")
            }
            |> Parser.inContext Error.InExpr
        , Parser.lazy (\_ -> subexpression)
        ]



-- EXPRESSION PARSERS: ACCESSORS -----------------------------------------------


{-| -}
access : Parser (Expr Span)
access =
    Parser.succeed (\expr accessor accessors -> Access expr (accessor :: accessors))
        |= Parser.lazy (\_ -> parenthesised)
        |. Util.whitespace
        |. symbol "."
        |. Parser.commit ()
        |= lowercaseName Set.empty
        |. Util.whitespace
        |= Parser.loop []
            (\accessors ->
                Parser.oneOf
                    [ Parser.succeed (\accessor -> accessor :: accessors)
                        |. symbol "."
                        |= lowercaseName Set.empty
                        |> Parser.map Parser.Loop
                    , Parser.succeed ()
                        |> Parser.map (\_ -> List.reverse accessors)
                        |> Parser.map Parser.Done
                    ]
            )
        |> Parser.backtrackable
        |> Span.parser Expr



-- EXPRESSION PARSERS: APPLICATION ---------------------------------------------


{-| -}
application : Config (Expr Span) -> Parser (Expr Span)
application config =
    Parser.succeed (\f arg args -> Application f (arg :: args))
        |= Parser.oneOf
            [ access
            , block config
            , Parser.lazy (\_ -> subexpression)
            , identifier
            ]
        |. Util.whitespace
        |= parenthesised
        |. Parser.commit ()
        |. Util.whitespace
        |= Parser.loop []
            (\args ->
                Parser.oneOf
                    [ Parser.succeed (\arg -> arg :: args)
                        |= parenthesised
                        |. Util.whitespace
                        |> Parser.map Parser.Loop
                        |> Parser.backtrackable
                    , Parser.succeed ()
                        |> Parser.map (\_ -> List.reverse args)
                        |> Parser.map Parser.Done
                    ]
            )
        |> Parser.backtrackable
        |> Span.parser Expr



-- EXPRESSION PARSERS: ANNOTATION ----------------------------------------------


annotation : Parser (Expr Span)
annotation =
    Parser.succeed Annotation
        |= parenthesised
        |. Util.whitespace
        |. keyword "as"
        |. Parser.commit ()
        |. Util.whitespace
        |= type_
        |> Parser.backtrackable
        |> Span.parser Expr



-- EXPRESSION PARSERS: BLOCKS --------------------------------------------------


{-| -}
block : Config (Expr Span) -> Parser (Expr Span)
block config =
    Parser.succeed Block
        |. symbol "{"
        |. Util.whitespace
        |= Parser.loop []
            (\bindings ->
                Parser.oneOf
                    [ Parser.succeed (\b -> b :: bindings)
                        |= binding config
                        |. Parser.commit ()
                        |. Util.whitespace
                        |> Parser.map Parser.Loop
                    , Parser.succeed ()
                        |> Parser.map (\_ -> List.reverse bindings)
                        |> Parser.map Parser.Done
                    ]
            )
        |. Util.whitespace
        |. keyword "ret"
        |. Parser.commit ()
        |= Parser.lazy (\_ -> expression)
        |. Util.whitespace
        |. symbol "}"
        |> Parser.backtrackable
        |> Span.parser Expr


{-| -}
binding : Config (Expr Span) -> Parser ( String, Expr Span )
binding config =
    Parser.oneOf
        [ Parser.succeed (Tuple.pair "_")
            |. keyword "run"
            |. Parser.commit ()
            |. Util.whitespace
            |= Parser.lazy (\_ -> expression)
            |> Parser.backtrackable
        , Parser.succeed Tuple.pair
            |. keyword "let"
            |. Parser.commit ()
            |. Util.whitespace
            |= lowercaseName keywords
            |. Util.whitespace
            |. symbol "="
            |. Util.whitespace
            |= Parser.lazy (\_ -> expression)
            |> Parser.backtrackable
        ]



-- EXPRESSION PARSERS: CONDITIONALS --------------------------------------------


{-| -}
conditional : Config (Expr Span) -> Parser (Expr Span)
conditional config =
    Parser.succeed Conditional
        |. keyword "if"
        |. Parser.commit ()
        |. Util.whitespace
        |= Parser.lazy (\_ -> expression)
        |. Util.whitespace
        |. keyword "then"
        |. Util.whitespace
        |= Parser.lazy (\_ -> expression)
        |. Util.whitespace
        |. keyword "else"
        |. Util.whitespace
        |= Parser.lazy (\_ -> expression)
        |> Parser.backtrackable
        |> Span.parser Expr



-- EXPRESSION PARSERS: IDENTIFIERS ---------------------------------------------


{-| -}
identifier : Parser (Expr Span)
identifier =
    Parser.succeed Identifier
        |= Parser.oneOf
            [ placeholder
            , local
            , scoped
            ]
        |> Span.parser Expr


{-| -}
placeholder : Parser Expr.Identifier
placeholder =
    Parser.succeed Expr.Placeholder
        |. symbol "_"
        |= Parser.oneOf
            [ Parser.succeed Just
                |= lowercaseName keywords
            , Parser.succeed Nothing
            ]


{-| -}
local : Parser Expr.Identifier
local =
    Parser.succeed Expr.Local
        |= lowercaseName keywords


{-| -}
scoped : Parser Expr.Identifier
scoped =
    Parser.succeed Expr.Scoped
        |= uppercaseName Set.empty
        |. symbol "."
        |= Parser.oneOf
            [ Parser.lazy (\_ -> scoped)
            , local
            ]



-- EXPRESSION PARSERS: LAMBDAS -------------------------------------------------


{-| -}
lambda : Config (Expr Span) -> Parser (Expr Span)
lambda config =
    Parser.succeed (\arg args body -> Lambda (arg :: args) body)
        |= pattern
        |. Util.whitespace
        |= Parser.loop []
            (\args ->
                Parser.oneOf
                    [ Parser.succeed (\arg -> arg :: args)
                        |= pattern
                        |. Util.whitespace
                        |> Parser.map Parser.Loop
                    , Parser.succeed ()
                        |> Parser.map (\_ -> List.reverse args)
                        |> Parser.map Parser.Done
                    ]
            )
        |. Util.whitespace
        |. symbol "=>"
        |. Parser.commit ()
        |. Util.whitespace
        |= Parser.lazy (\_ -> expression)
        |> Parser.backtrackable
        |> Span.parser Expr



-- EXPRESSION PARSERS: LITERALS ------------------------------------------------


{-| -}
literal : Config (Expr Span) -> Parser (Expr Span)
literal config =
    Parser.succeed Literal
        |= Parser.oneOf
            [ array config
            , boolean
            , number
            , record config
            , string
            , template config
            , undefined
            , variant
            ]
        |> Span.parser Expr


{-| -}
array : Config (Expr Span) -> Parser (Expr.Literal (Expr Span))
array config =
    Parser.succeed Expr.Array
        |= Parser.sequence
            { start = Parser.Token "[" <| Error.expectingSymbol "["
            , separator = Parser.Token "," <| Error.expectingSymbol ","
            , end = Parser.Token "]" <| Error.expectingSymbol "]"
            , item = Parser.lazy (\_ -> expression)
            , spaces = Util.whitespace
            , trailing = Parser.Forbidden
            }


{-| -}
boolean : Parser (Expr.Literal expr)
boolean =
    Parser.succeed Expr.Boolean
        |= Parser.oneOf
            [ Parser.succeed True
                |. Parser.keyword (Parser.Token "true" <| Error.expectingKeyword "true")
            , Parser.succeed False
                |. Parser.keyword (Parser.Token "false" <| Error.expectingKeyword "false")
            ]


{-| -}
number : Parser (Expr.Literal expr)
number =
    let
        numberConfig =
            { int = Ok Basics.toFloat
            , hex = Ok Basics.toFloat
            , octal = Ok Basics.toFloat
            , binary = Ok Basics.toFloat
            , float = Ok identity
            , invalid = Error.expectingNumber
            , expecting = Error.expectingNumber
            }
    in
    Parser.succeed Expr.Number
        |= Parser.oneOf
            [ Parser.succeed Basics.negate
                |. Parser.symbol (Parser.Token "-" <| Error.expectingSymbol "-")
                |= Parser.number numberConfig
            , Parser.number numberConfig
            ]
        |. Parser.oneOf
            [ Parser.chompIf Char.isAlpha Error.expectingNumber
                |> Parser.andThen (\_ -> Parser.problem Error.expectingNumber)
            , Parser.succeed ()
            ]


{-| -}
record : Config (Expr Span) -> Parser (Expr.Literal (Expr Span))
record config =
    Parser.succeed Expr.Record
        |= Parser.sequence
            { start = Parser.Token "{" <| Error.expectingSymbol "{"
            , separator = Parser.Token "," <| Error.expectingSymbol ","
            , end = Parser.Token "}" <| Error.expectingSymbol "}"
            , item =
                Parser.oneOf
                    [ Parser.succeed Tuple.pair
                        |= lowercaseName keywords
                        |. Util.whitespace
                        |. Parser.symbol (Parser.Token ":" <| Error.expectingSymbol ":")
                        |. Parser.commit ()
                        |. Util.whitespace
                        |= Parser.lazy (\_ -> expression)
                        |> Parser.backtrackable

                    -- We support record literal shorthand like JavaScript that
                    -- lets you write `{ foo }` as a shorthand for writing
                    -- `{ foo: foo }`. Because our expressions are annotated with
                    -- their source Span, we do some gymnastics to get that
                    -- Span data before we construct the identifier.
                    , Parser.succeed (\start key end -> ( Span.fromTuples start end, key ))
                        |= Parser.getPosition
                        |= lowercaseName keywords
                        |= Parser.getPosition
                        |> Parser.map (\( loc, key ) -> ( key, Expr loc (Identifier (Expr.Local key)) ))
                    ]
            , spaces = Util.whitespace
            , trailing = Parser.Forbidden
            }
        |> Parser.backtrackable


{-| -}
string : Parser (Expr.Literal expr)
string =
    Parser.succeed Expr.String
        |= quotedString '"'


{-| -}
template : Config (Expr Span) -> Parser (Expr.Literal (Expr Span))
template config =
    let
        char =
            Parser.oneOf
                [ Parser.succeed identity
                    |. Parser.token (Parser.Token "\\" <| Error.expectingSymbol "\\")
                    |= Parser.oneOf
                        [ Parser.map (\_ -> '\\') (Parser.token (Parser.Token "\\" <| Error.expectingSymbol "\\"))
                        , Parser.map (\_ -> '"') (Parser.token (Parser.Token "\"" <| Error.expectingSymbol "\"")) -- " (elm-vscode workaround)
                        , Parser.map (\_ -> '\'') (Parser.token (Parser.Token "'" <| Error.expectingSymbol "'"))
                        , Parser.map (\_ -> '\n') (Parser.token (Parser.Token "n" <| Error.expectingSymbol "n"))
                        , Parser.map (\_ -> '\t') (Parser.token (Parser.Token "t" <| Error.expectingSymbol "t"))
                        , Parser.map (\_ -> '\u{000D}') (Parser.token (Parser.Token "r" <| Error.expectingSymbol "r"))
                        ]
                , Parser.token (Parser.Token "`" <| Error.expectingSymbol "`")
                    |> Parser.andThen (\_ -> Parser.problem <| Error.unexpectedChar '`')
                , Parser.chompIf ((/=) '\n') Error.expectingChar
                    |> Parser.getChompedString
                    |> Parser.andThen
                        (String.uncons
                            >> Maybe.map (Tuple.first >> Parser.succeed)
                            >> Maybe.withDefault (Parser.problem <| Error.internalParseError "Multiple characters chomped in `parseChar`")
                        )
                ]

        -- Each template segment should either be a String or an expression to
        -- be interpolated. Right now instead of String segments we have Char
        -- segments, so we use this function in a fold to join all the characters
        -- into a strings.
        joinSegments segment segments =
            case ( segment, segments ) of
                ( Data.Either.Left c, (Data.Either.Left s) :: rest ) ->
                    Data.Either.Left (String.cons c s) :: rest

                ( Data.Either.Left c, rest ) ->
                    Data.Either.Left (String.fromChar c) :: rest

                ( Data.Either.Right e, rest ) ->
                    Data.Either.Right e :: rest
    in
    Parser.succeed (List.foldl joinSegments [] >> Expr.Template)
        |. Parser.symbol (Parser.Token "`" <| Error.expectingSymbol "`")
        |. Parser.commit ()
        |= Parser.loop []
            (\segments ->
                Parser.oneOf
                    [ Parser.succeed (\expr -> Data.Either.Right expr :: segments)
                        |. Parser.symbol (Parser.Token "${" <| Error.expectingSymbol "${")
                        |= Parser.lazy (\_ -> expression)
                        |. Parser.symbol (Parser.Token "}" <| Error.expectingSymbol "}")
                        |> Parser.map Parser.Loop
                    , Parser.succeed (\c -> Data.Either.Left c :: segments)
                        |= char
                        |> Parser.backtrackable
                        |> Parser.map Parser.Loop
                    , Parser.succeed segments
                        |> Parser.map Parser.Done
                    ]
            )
        |. Parser.symbol (Parser.Token "`" <| Error.expectingSymbol "`")


{-| -}
undefined : Parser (Expr.Literal expr)
undefined =
    Parser.succeed Expr.Undefined
        |. symbol "()"


{-| -}
variant : Parser (Expr.Literal (Expr Span))
variant =
    Parser.succeed Expr.Variant
        |. symbol "#"
        |= lowercaseName Set.empty
        |. Util.whitespace
        |= Parser.loop []
            (\exprs ->
                Parser.oneOf
                    [ Parser.succeed (\expr -> expr :: exprs)
                        |= parenthesised
                        |. Util.whitespace
                        |> Parser.map Parser.Loop
                    , Parser.succeed ()
                        |> Parser.map (\_ -> List.reverse exprs)
                        |> Parser.map Parser.Done
                    ]
            )



-- EXPRESSION PARSERS: MATCHES -------------------------------------------------


{-| -}
match : Config (Expr Span) -> Parser (Expr Span)
match config =
    Parser.succeed Match
        |. keyword "where"
        |. Parser.commit ()
        |. Util.whitespace
        |= Parser.lazy (\_ -> expression)
        |. Util.whitespace
        |= Parser.loop []
            (\cases ->
                Parser.oneOf
                    [ Parser.succeed (\pat guard body -> ( pat, guard, body ) :: cases)
                        |. keyword "is"
                        |. Util.whitespace
                        |= pattern
                        |. Util.whitespace
                        |= Parser.oneOf
                            [ Parser.succeed Just
                                |. keyword "if"
                                |. Util.whitespace
                                |= prattExpression
                                    -- These parsers start with a keyword
                                    [ conditional
                                    , match

                                    -- These parsers parse sub expressions
                                    --, annotation
                                    , application
                                    , Pratt.literal access

                                    --
                                    , block
                                    , Pratt.literal identifier
                                    , literal

                                    -- Subexpressions are wrapped in parentheses.
                                    , Pratt.literal (Parser.lazy (\_ -> subexpression))
                                    ]
                            , Parser.succeed Nothing
                            ]
                        |. Util.whitespace
                        |. symbol "=>"
                        |. Util.whitespace
                        |= Parser.lazy (\_ -> expression)
                        |> Parser.map Parser.Loop
                    , Parser.succeed ()
                        |> Parser.map (\_ -> List.reverse cases)
                        |> Parser.map Parser.Done
                    ]
            )
        |> Parser.backtrackable
        |> Span.parser Expr



--                                                                            --
-- PATTERN PARSERS -------------------------------------------------------------
--                                                                            --


{-| -}
pattern : Parser Expr.Pattern
pattern =
    let
        patterns =
            Parser.oneOf
                [ arrayDestructure
                , literalPattern
                , wildcard
                , name
                , recordDestructure
                , templateDestructure
                , typeof
                , variantDestructure
                ]
    in
    Parser.oneOf
        [ Parser.succeed Basics.identity
            |. symbol "("
            |. Util.whitespace
            |= patterns
            |. Util.whitespace
            |. symbol ")"
        , patterns
        ]


{-| -}
arrayDestructure : Parser Expr.Pattern
arrayDestructure =
    Parser.succeed Expr.ArrayDestructure
        |. symbol "["
        |. Parser.commit ()
        |. Util.whitespace
        |= Parser.oneOf
            [ Parser.succeed (::)
                |= Parser.lazy (\_ -> pattern)
                |. Util.whitespace
                |= Parser.loop []
                    (\patterns ->
                        Parser.oneOf
                            [ Parser.succeed (\pat -> pat :: patterns)
                                |. symbol ","
                                |. Util.whitespace
                                |= Parser.lazy (\_ -> pattern)
                                |> Parser.backtrackable
                                |> Parser.map Parser.Loop
                            , Parser.succeed (\pat -> pat :: patterns)
                                |. symbol ","
                                |. Util.whitespace
                                |= spread
                                |> Parser.map List.reverse
                                |> Parser.map Parser.Done
                            , Parser.succeed ()
                                |> Parser.map (\_ -> List.reverse patterns)
                                |> Parser.map Parser.Done
                            ]
                    )
            , Parser.succeed []
            ]
        |. Util.whitespace
        |. symbol "]"
        |> Parser.backtrackable


{-| -}
literalPattern : Parser Expr.Pattern
literalPattern =
    Parser.succeed Expr.LiteralPattern
        |= Parser.oneOf
            [ boolean
            , number
            , string
            , undefined
            ]


{-| -}
name : Parser Expr.Pattern
name =
    Parser.succeed Expr.Name
        |= lowercaseName keywords


{-| -}
recordDestructure : Parser Expr.Pattern
recordDestructure =
    let
        keyAndPattern =
            Parser.succeed Tuple.pair
                |= lowercaseName keywords
                |. Util.whitespace
                |= Parser.oneOf
                    [ Parser.succeed Just
                        |. symbol ":"
                        |. Util.whitespace
                        |= Parser.lazy (\_ -> pattern)
                    , Parser.succeed Nothing
                    ]
    in
    Parser.succeed Expr.RecordDestructure
        |. symbol "{"
        |. Parser.commit ()
        |. Util.whitespace
        |= Parser.oneOf
            [ Parser.succeed (::)
                |= keyAndPattern
                |. Util.whitespace
                |= Parser.loop []
                    (\patterns ->
                        Parser.oneOf
                            [ Parser.succeed (\pat -> pat :: patterns)
                                |. symbol ","
                                |. Util.whitespace
                                |= keyAndPattern
                                |> Parser.backtrackable
                                |> Parser.map Parser.Loop
                            , Parser.succeed Basics.identity
                                |. symbol ","
                                |. Util.whitespace
                                |= spread
                                -- We need to get the name of the binding
                                -- introduced by the spread pattern so we can
                                -- store it in the pattern list with a "key".
                                |> Parser.andThen
                                    (\pat ->
                                        case pat of
                                            Expr.Spread key ->
                                                (( key, Just pat ) :: patterns)
                                                    |> Parser.succeed

                                            _ ->
                                                Error.internalParseError ""
                                                    |> Parser.problem
                                    )
                                |> Parser.map List.reverse
                                |> Parser.map Parser.Done
                            , Parser.succeed ()
                                |> Parser.map (\_ -> List.reverse patterns)
                                |> Parser.map Parser.Done
                            ]
                    )
            , Parser.succeed []
            ]
        |. Util.whitespace
        |. symbol "}"
        |> Parser.backtrackable


{-| -}
spread : Parser Expr.Pattern
spread =
    Parser.succeed Expr.Spread
        |. symbol "..."
        |. Parser.commit ()
        |= lowercaseName keywords
        |> Parser.backtrackable


{-| -}
templateDestructure : Parser Expr.Pattern
templateDestructure =
    let
        char =
            Parser.oneOf
                [ Parser.succeed identity
                    |. Parser.token (Parser.Token "\\" <| Error.expectingSymbol "\\")
                    |= Parser.oneOf
                        [ Parser.map (\_ -> '\\') (Parser.token (Parser.Token "\\" <| Error.expectingSymbol "\\"))
                        , Parser.map (\_ -> '"') (Parser.token (Parser.Token "\"" <| Error.expectingSymbol "\"")) -- " (elm-vscode workaround)
                        , Parser.map (\_ -> '\'') (Parser.token (Parser.Token "'" <| Error.expectingSymbol "'"))
                        , Parser.map (\_ -> '\n') (Parser.token (Parser.Token "n" <| Error.expectingSymbol "n"))
                        , Parser.map (\_ -> '\t') (Parser.token (Parser.Token "t" <| Error.expectingSymbol "t"))
                        , Parser.map (\_ -> '\u{000D}') (Parser.token (Parser.Token "r" <| Error.expectingSymbol "r"))
                        ]
                , Parser.token (Parser.Token "`" <| Error.expectingSymbol "`")
                    |> Parser.andThen (\_ -> Parser.problem <| Error.unexpectedChar '`')
                , Parser.chompIf ((/=) '\n') Error.expectingChar
                    |> Parser.getChompedString
                    |> Parser.andThen
                        (String.uncons
                            >> Maybe.map (Tuple.first >> Parser.succeed)
                            >> Maybe.withDefault (Parser.problem <| Error.internalParseError "Multiple characters chomped in `parseChar`")
                        )
                ]

        -- Each template segment should either be a String or an expression to
        -- be interpolated. Right now instead of String segments we have Char
        -- segments, so we use this function in a fold to join all the characters
        -- into a strings.
        joinSegments segment segments =
            case ( segment, segments ) of
                ( Data.Either.Left c, (Data.Either.Left s) :: rest ) ->
                    Data.Either.Left (String.cons c s) :: rest

                ( Data.Either.Left c, rest ) ->
                    Data.Either.Left (String.fromChar c) :: rest

                ( Data.Either.Right e, rest ) ->
                    Data.Either.Right e :: rest
    in
    Parser.succeed (List.foldl joinSegments [] >> Expr.TemplateDestructure)
        |. symbol "`"
        |. Parser.commit ()
        |= Parser.loop []
            (\segments ->
                Parser.oneOf
                    [ Parser.succeed (\expr -> Data.Either.Right expr :: segments)
                        |. symbol "${"
                        |= Parser.lazy (\_ -> pattern)
                        |. symbol "}"
                        |> Parser.map Parser.Loop
                    , Parser.succeed (\c -> Data.Either.Left c :: segments)
                        |= char
                        |> Parser.backtrackable
                        |> Parser.map Parser.Loop
                    , Parser.succeed segments
                        |> Parser.map Parser.Done
                    ]
            )
        |. symbol "`"
        |> Parser.backtrackable


{-| -}
typeof : Parser Expr.Pattern
typeof =
    Parser.succeed Expr.Typeof
        |. symbol "@"
        |. Parser.commit ()
        |= uppercaseName Set.empty
        |. Util.whitespace
        |= Parser.lazy (\_ -> pattern)
        |> Parser.backtrackable


{-| -}
variantDestructure : Parser Expr.Pattern
variantDestructure =
    Parser.succeed Expr.VariantDestructure
        |. symbol "#"
        |. Parser.commit ()
        |= lowercaseName Set.empty
        |. Util.whitespace
        |= Parser.loop []
            (\patterns ->
                Parser.oneOf
                    [ Parser.succeed (\pat -> pat :: patterns)
                        |= Parser.lazy (\_ -> pattern)
                        |. Util.whitespace
                        |> Parser.map Parser.Loop
                    , Parser.succeed ()
                        |> Parser.map (\_ -> List.reverse patterns)
                        |> Parser.map Parser.Done
                    ]
            )
        |> Parser.backtrackable


{-| -}
wildcard : Parser Expr.Pattern
wildcard =
    Parser.succeed Expr.Wildcard
        |. symbol "_"
        |= Parser.oneOf
            [ lowercaseName Set.empty
                |> Parser.map Just
            , Parser.succeed Nothing
            ]



--                                                                            --
-- TYPE PARSERS ----------------------------------------------------------------
--                                                                            --


type_ : Parser Type
type_ =
    Parser.oneOf
        [ fun
        , app
        , var
        , con
        , any
        , rec
        , sum
        , hole
        , Parser.lazy (\_ -> subtype)
        , Parser.problem Error.expectingType
        ]


subtype : Parser Type
subtype =
    Parser.succeed identity
        |. symbol "("
        |. Util.whitespace
        |= Parser.lazy (\_ -> type_)
        |. Util.whitespace
        |. symbol ")"
        |> Parser.backtrackable


var : Parser Type
var =
    Parser.succeed Type.Var
        |= lowercaseName keywords


con : Parser Type
con =
    Parser.oneOf
        [ Parser.succeed Type.Con
            |= uppercaseName Set.empty
        , Parser.succeed (Type.Con "()")
            |. Parser.symbol (Parser.Token "()" <| Error.expectingSymbol "()")
        ]


app : Parser Type
app =
    let
        typeWithoutApp =
            Parser.oneOf
                [ subtype
                , var
                , con
                , rec
                , sum
                , any
                , hole
                ]
    in
    Parser.succeed (\con_ arg args -> Type.App con_ (arg :: args))
        |= typeWithoutApp
        |. Util.whitespace
        |= typeWithoutApp
        |. Util.whitespace
        |= Parser.loop []
            (\args ->
                Parser.oneOf
                    [ Parser.succeed (\arg -> arg :: args)
                        |= typeWithoutApp
                        |. Util.whitespace
                        |> Parser.map Parser.Loop
                    , Parser.succeed (List.reverse args)
                        |> Parser.map Parser.Done
                    ]
            )
        |> Parser.backtrackable


fun : Parser Type
fun =
    let
        typeWithoutFun =
            Parser.oneOf
                [ subtype
                , app
                , any
                , var
                , con
                , rec
                , sum
                , hole
                ]
    in
    Parser.succeed Type.Fun
        |= typeWithoutFun
        |. Util.whitespace
        |. Parser.oneOf
            [ symbol "->"
            , symbol "→"
            ]
        |. Util.whitespace
        |= Parser.lazy (\_ -> type_)
        |> Parser.backtrackable


rec : Parser Type
rec =
    Parser.succeed (Type.Rec << Dict.fromList)
        |= Parser.sequence
            { start = Parser.Token "{" (Error.expectingSymbol "{")
            , separator = Parser.Token "," (Error.expectingSymbol ",")
            , end = Parser.Token "}" (Error.expectingSymbol "}")
            , spaces = Util.whitespace
            , item =
                Parser.succeed Tuple.pair
                    |= lowercaseName keywords
                    |. Util.whitespace
                    |. symbol ":"
                    |. Util.whitespace
                    |= Parser.lazy (\_ -> type_)
            , trailing = Parser.Forbidden
            }


sum : Parser Type
sum =
    Parser.succeed (\first rest -> Type.Sum <| Dict.fromList (first :: rest))
        |= variantT
        |= Parser.loop []
            (\variants ->
                Parser.oneOf
                    [ Parser.succeed (\( tag, params ) -> ( tag, params ) :: variants)
                        |= variantT
                        |> Parser.map Parser.Loop
                    , Parser.succeed ()
                        |> Parser.map (\_ -> List.reverse variants)
                        |> Parser.map Parser.Done
                    ]
            )


variantT : Parser ( String, List Type )
variantT =
    let
        typeWithoutApp =
            Parser.oneOf
                [ subtype
                , var
                , con
                , rec
                , any
                , hole
                ]
    in
    Parser.succeed Tuple.pair
        |. symbol "#"
        |. Parser.commit ()
        |= lowercaseName Set.empty
        |. Util.whitespace
        |= Parser.loop []
            (\params ->
                Parser.oneOf
                    [ Parser.succeed (\param -> param :: params)
                        |= typeWithoutApp
                        |. Util.whitespace
                        |> Parser.map Parser.Loop
                        |> Parser.backtrackable
                    , Parser.succeed ()
                        |> Parser.map (\_ -> List.reverse params)
                        |> Parser.map Parser.Done
                    ]
            )


any : Parser Type
any =
    Parser.succeed Type.Any
        |. symbol "*"


hole : Parser Type
hole =
    Parser.succeed Type.Hole
        |. symbol "?"



--                                                                            --
-- UTILITIES -------------------------------------------------------------------
--                                                                            --


{-| -}
lowercaseName : Set String -> Parser String
lowercaseName reserved =
    Parser.variable
        { expecting = Error.expectingCamelCase
        , start = \c -> Char.isLower c || c == '_'
        , inner = \c -> Char.isAlphaNum c || c == '_'
        , reserved = reserved
        }


{-| -}
uppercaseName : Set String -> Parser String
uppercaseName reserved =
    Parser.variable
        { expecting = Error.expectingCapitalCase
        , start = Char.isUpper
        , inner = \c -> Char.isAlphaNum c || c == '_'
        , reserved = reserved
        }


{-| -}
symbol : String -> Parser ()
symbol s =
    Parser.symbol (Parser.Token s <| Error.expectingSymbol s)


{-| -}
keyword : String -> Parser ()
keyword s =
    Parser.keyword (Parser.Token s <| Error.expectingKeyword s)
        |. Parser.commit ()


{-| -}
operator : String -> Parser ()
operator s =
    Parser.symbol (Parser.Token s <| Error.expectingOperator s)


{-| -}
quotedString : Char -> Parser String
quotedString quote =
    let
        s =
            String.fromChar quote

        char =
            Parser.oneOf
                [ Parser.succeed identity
                    |. symbol s
                    |= Parser.oneOf
                        [ Parser.map (\_ -> '\\') (symbol "\\")
                        , Parser.map (\_ -> '"') (symbol "\"") -- " (elm-vscode workaround)
                        ]
                , symbol s
                    |> Parser.andThen (\_ -> Parser.problem <| Error.unexpectedChar quote)
                , Parser.chompIf ((/=) '\n') Error.expectingChar
                    |> Parser.getChompedString
                    |> Parser.andThen
                        (String.uncons
                            >> Maybe.map (Tuple.first >> Parser.succeed)
                            >> Maybe.withDefault (Parser.problem <| Error.internalParseError "Multiple characters chomped in `character`")
                        )
                ]
    in
    Parser.succeed String.fromList
        |. symbol s
        |= Parser.loop []
            (\cs ->
                Parser.oneOf
                    [ Parser.succeed (\c -> c :: cs)
                        |= char
                        |> Parser.backtrackable
                        |> Parser.map Parser.Loop
                    , Parser.succeed (List.reverse cs)
                        |> Parser.map Parser.Done
                    ]
            )
        |. symbol s


{-| -}
keywords : Set String
keywords =
    Set.fromList <|
        List.concat
            -- Imports
            [ [ "import", "as", "exposing", "ext", "pkg" ]

            -- Declarations
            , [ "pub", "extern", "run" ]

            -- Bindings
            , [ "fun", "let", "ret" ]

            -- Conditionals
            , [ "if", "then", "else" ]

            -- Pattern matching
            , [ "where", "is" ]

            -- Literals
            , [ "true", "false" ]
            ]


{-| -}
types : Set String
types =
    Set.fromList
        [ "Array"
        , "Boolean"
        , "Number"
        , "String"
        ]
