{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Newtype.Parser where

import Control.Applicative hiding (many, some)
import Control.Monad
import Control.Monad.Combinators.Expr
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Void
import Newtype.Syntax
import Text.Megaparsec hiding (State)
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L
import Text.Megaparsec.Debug

type Parser = Parsec Void Text

main :: IO ()
main = putStrLn "main"

spaceConsumer :: Parser ()
spaceConsumer =
  L.space
    space1
    (L.skipLineComment "//")
    (L.skipBlockComment "{-" "-}")

lexeme :: Parser a -> Parser a
lexeme = L.lexeme spaceConsumer

symbol :: Text -> Parser Text
symbol = L.symbol spaceConsumer

stringLiteral :: Parser String
stringLiteral = char '\"' *> manyTill L.charLiteral (char '\"')

integer :: Parser Integer
integer = lexeme L.decimal

float :: Parser Double
float = lexeme L.float

lparen :: Parser Text
lparen = symbol "("

rparen :: Parser Text
rparen = symbol ")"

parens :: Parser a -> Parser a
parens = between lparen rparen

lbrace :: Parser Text
lbrace = symbol "{"

rbrace :: Parser Text
rbrace = symbol "}"

braces :: Parser a -> Parser a
braces = between lbrace rbrace

langle :: Parser Text
langle = symbol "<"

rangle :: Parser Text
rangle = symbol ">"

angles :: Parser Text -> Parser Text
angles = between langle rangle

lbracket :: Parser Text
lbracket = symbol "["

rbracket :: Parser Text
rbracket = symbol "]"

brackets :: Parser a -> Parser a
brackets = between lbracket rbracket

semicolon :: Parser Text
semicolon = symbol ";"

pipe :: Parser Text
pipe = symbol "|"

amp :: Parser Text
amp = symbol "&"

comma :: Parser Text
comma = symbol ","

colon :: Parser Text
colon = symbol ":"

qmark :: Parser Text
qmark = symbol "?"

pound :: Parser Text
pound = symbol "#"

caret :: Parser Text
caret = symbol "^"

dot :: Parser Text
dot = symbol "."

equals :: Parser Text
equals = symbol "="

-- list of reserved words
reservedWords :: [String]
reservedWords =
  [ "from",
    "if",
    "else",
    "then",
    "while",
    "for",
    "goto",
    "require",
    "import",
    "from",
    "as",
    "do",
    "yield",
    "await",
    "async",
    "readonly"
  ]

keyword :: Text -> Parser Text
keyword txt = lexeme (string txt <* notFollowedBy alphaNumChar)

identifier :: Parser String
identifier = (lexeme . try) (p >>= check)
  where
    p = (:) <$> (letterChar <|> underscore <|> dollar) <*> many (alphaNumChar <|> underscore <|> dollar)
    check x =
      if x `elem` reservedWords
        then fail $ "keyword " ++ show x ++ " cannot be an identifier"
        else return x

underscore :: Parser (Token Text)
underscore = char '_'
{-# INLINE underscore #-}

dollar :: Parser (Token Text)
dollar = char '$'
{-# INLINE dollar #-}

bool :: Parser Bool
bool = choice [True <$ keyword "true", False <$ keyword "false"]

pProgram :: Parser Program
pProgram =
  do
    statements <- many pStatement <* eof
    return (Program statements)

pImportClause :: Parser ImportClause
pImportClause =
  ImportClauseNamed <$> parens (pSpecifier `sepBy` comma)
  where
    pSpecifier = do
      binding <- identifier
      alias <- optional $ do
        void $ keyword "as"
        identifier
      case alias of
        Just importedBinding -> return (ImportedAlias binding importedBinding)
        Nothing -> return (ImportedBinding binding)

pStatement :: Parser Statement
pStatement =
  choice
    [ pExport,
      pImport,
      pTypeDefinition
    ]
  where
    pExport = ExportStatement <$ string "export"
    pImport = do
      void $ keyword "import"
      fromClause <- lexeme stringLiteral <?> "from clause"
      importClause <- pImportClause
      return ImportDeclaration {..}
    pTypeDefinition = do
      void $ keyword "type"
      name <- identifier
      void equals
      body <- pExpression
      return TypeDefinition {..}
      where
        params = Nothing

-- Same as expression, but with recursive terms removed
pTerm :: Parser Expression
pTerm =
  choice
    [ try pTypeApplication,
      try (parens pTypeApplication),
      try pTuple,
      parens pOperator,
      pExtendsExpression,
      pNumberIntegerLiteral,
      pNumberDoubleLiteral,
      pBooleanLiteral,
      pStringLiteral,
      pIdentifier,
      -- Not actually valid outside of the extends expression
      -- but make my life a lot easier
      pInferIdentifier,
      pObjectLiteral
    ]

pExpression :: Parser Expression
pExpression =
  choice
    [ pOperator,
      pTerm
    ]

pOperator :: Parser Expression
pOperator = makeExprParser pTerm operatorTable

operatorTable :: [[Operator Parser Expression]]
operatorTable =
  [ [InfixL $ Intersection <$ amp],
    [InfixL $ Union <$ pipe]
  ]

pInferIdentifier :: Parser Expression
pInferIdentifier = caret >> InferIdentifier <$> identifier <?> "identifier"

pNumberIntegerLiteral :: Parser Expression
pNumberIntegerLiteral = NumberIntegerLiteral <$> integer

pNumberDoubleLiteral :: Parser Expression
pNumberDoubleLiteral = NumberDoubleLiteral <$> float

pBooleanLiteral :: Parser Expression
pBooleanLiteral = BooleanLiteral <$> bool

pStringLiteral :: Parser Expression
pStringLiteral = StringLiteral <$> stringLiteral

pTuple :: Parser Expression
pTuple = Tuple <$> brackets (pExpression `sepBy` comma)

pIdentifier :: Parser Expression
pIdentifier = Identifier <$> identifier <?> "identifier"

pExtendsExpression :: Parser Expression
pExtendsExpression = do
  void $ keyword "if"
  lhs <- pExpression
  op <-
    choice
      [ ExtendsLeft <$ keyword "<:",
        ExtendsRight <$ keyword ":>",
        NotEquals <$ keyword "!=",
        Equals <$ keyword "=="
      ]
  rhs <- pExpression
  void $ keyword "then"
  ifBody <- pExpression
  elseBody <- do optional (keyword "else" >> pExpression)
  return
    ( ExtendsExpression
        { elseBody = fromMaybe never elseBody,
          ..
        }
    )
  where
    never = Identifier "never"

pObjectLiteral :: Parser Expression
pObjectLiteral =
  ObjectLiteral <$> braces (pObjectLiteralProperty `sepBy` comma)

pTypeApplication :: Parser Expression
pTypeApplication = do
  typeName <- identifier <?> "type function"
  -- Give Identifier a higher precedence when it's nested in an existing
  -- expression
  params <-
    (some . choice $ [pIdentifier, pExpression]) <?> "type parameter"
  return (TypeApplication typeName params)

pObjectLiteralProperty :: Parser ObjectLiteralProperty
pObjectLiteralProperty = do
  isReadonly <-
    optional . choice $
      [ True <$ keyword "readonly",
        False <$ keyword "-readonly"
      ]

  key <- identifier
  isOptional <-
    optional . choice $
      [ True <$ qmark,
        False <$ keyword "-?"
      ]
  void colon
  value <- pExpression
  return (KeyValue {..})
