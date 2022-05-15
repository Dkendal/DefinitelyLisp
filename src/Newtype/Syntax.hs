{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Newtype.Syntax where

import Control.Monad
import Prettyprinter

class TypescriptAST a where
  simplify :: a -> a

newtype Program = Program {statements :: [Statement]}
  deriving (Eq, Show)

instance Pretty Program where
  pretty (Program statements) = prettyList statements

data Statement
  = ImportDeclaration
      { importClause :: ImportClause,
        fromClause :: String
      }
  | ExportStatement
  | TypeDefinition
      { name :: String,
        params :: Maybe TypeParams,
        body :: Expression
      }
  | InterfaceDefinition
      { name :: String,
        params :: Maybe TypeParams,
        extends :: [Expression],
        props :: [ObjectLiteralProperty]
      }
  deriving (Eq, Show)

instance Pretty Statement where
  pretty ImportDeclaration {..} =
    "import" <+> pretty importClause <+> "from" <+> dquotes (pretty fromClause)
  pretty TypeDefinition {..} =
    group ("type" <+> pretty name) <> group (nest 2 (line <> "=" <+> pretty body))
  pretty ExportStatement = emptyDoc
  pretty InterfaceDefinition {..} =
    (group "interface" <+> pretty name) <+> vsep [lbrace, body, rbrace]
    where
      body = indent 2 (align (vsep (map ((<> semi) . pretty) props)))

  prettyList statements = vsep (map pretty statements)

data ImportClause
  = ImportClauseDefault String
  | ImportClauseNS String
  | ImportClauseNamed [ImportSpecifier]
  | ImportClauseDefaultAndNS
      { defaultBinding :: String,
        namespaceBinding :: String
      }
  | ImportClauseDefaultAndNamed
      { defaultBinding :: String,
        namedBindings :: [ImportSpecifier]
      }
  deriving (Eq, Show)

instance Pretty ImportClause where
  pretty (ImportClauseDefault binding) = pretty binding
  pretty (ImportClauseNS binding) = "* as " <> pretty binding
  pretty (ImportClauseNamed namedBindings) = prettyList namedBindings
  pretty ImportClauseDefaultAndNS {..} = pretty defaultBinding <+> pretty namespaceBinding
  pretty ImportClauseDefaultAndNamed {..} = pretty defaultBinding <+> prettyList namedBindings

data ImportSpecifier
  = ImportedBinding String
  | ImportedAlias {from :: String, to :: String}
  deriving (Eq, Show)

instance Pretty ImportSpecifier where
  pretty (ImportedBinding binding) = pretty binding
  pretty ImportedAlias {..} = pretty from <+> "as" <+> pretty to
  prettyList lst =
    braces . hsep . punctuate comma . map pretty $ lst

data TypeParams = TypeParams
  deriving (Eq, Show)

data Expression
  = StringLiteral String
  | NumberIntegerLiteral Integer
  | NumberDoubleLiteral Double
  | BooleanLiteral Bool
  | ObjectLiteral [ObjectLiteralProperty]
  | TypeApplication String [Expression]
  | Identifier String
  | InferIdentifier String
  | Tuple [Expression]
  | ExtendsExpression
      { lhs :: Expression,
        negate :: Bool,
        op :: ComparisionOperator,
        rhs :: Expression,
        ifBody :: Expression,
        elseBody :: Expression
      }
  | Union Expression Expression
  | Intersection Expression Expression
  | CaseStatement Expression [(Expression, Expression)]
  deriving (Eq, Show)

instance TypescriptAST Expression where
  simplify (CaseStatement term [(rhs, ifBody)]) =
    ExtendsExpression
      { lhs = simplify term,
        op = ExtendsLeft,
        negate = False,
        elseBody = never,
        ..
      }
  simplify (CaseStatement term ((rhs, ifBody) : tl)) =
    ExtendsExpression
      { lhs = simplify term,
        op = ExtendsLeft,
        negate = False,
        elseBody = simplify (CaseStatement term tl),
        ..
      }
  simplify a = a

instance Pretty Expression where
  pretty (NumberIntegerLiteral value) = pretty value
  pretty (NumberDoubleLiteral value) = pretty value
  pretty (BooleanLiteral True) = "true"
  pretty (BooleanLiteral False) = "false"
  pretty (StringLiteral value) = dquotes . pretty $ value
  pretty (TypeApplication typeName []) = pretty typeName
  pretty (TypeApplication typeName params) = pretty typeName <> (angles . hsep . punctuate comma . map pretty $ params)
  pretty (ObjectLiteral props) =
    group
      ( encloseSep
          (flatAlt "{ " "{")
          (flatAlt " }" "}")
          ", "
          (map pretty props)
      )
  pretty (Identifier name) = pretty name
  pretty (InferIdentifier name) = group "infer" <+> pretty name
  pretty ExtendsExpression {negate = True, ..} =
    pretty
      ExtendsExpression
        { negate = False,
          ifBody = elseBody,
          elseBody = ifBody,
          ..
        }
  pretty ExtendsExpression {op = ExtendsLeft, ..} =
    pretty lhs <+> "extends" <+> pretty rhs
      <+> "?"
      <+> pretty ifBody
      <+> ":"
      <+> pretty elseBody
  pretty ExtendsExpression {op = ExtendsRight, ..} =
    pretty
      ExtendsExpression
        { lhs = rhs,
          rhs = lhs,
          op = ExtendsLeft,
          ..
        }
  pretty ExtendsExpression {op = Equals, ..} =
    pretty
      ExtendsExpression
        { lhs = Tuple [lhs],
          rhs = Tuple [rhs],
          op = ExtendsLeft,
          ..
        }
  pretty ExtendsExpression {op = NotEquals, ..} =
    pretty
      ExtendsExpression
        { lhs = Tuple [lhs],
          rhs = Tuple [rhs],
          op = ExtendsLeft,
          ifBody = elseBody,
          elseBody = ifBody,
          ..
        }
  pretty (Tuple exprs) = prettyList exprs
  pretty (Intersection left right) =
    fmt left <> line <> "&" <+> fmt right
    where
      fmt (Union a b) = prettyOpList (Union a b)
      fmt a = pretty a
  pretty (Union left right) =
    fmt left <> line <> "|" <+> fmt right
    where
      fmt (Intersection a b) = prettyOpList (Intersection a b)
      fmt a = pretty a
  pretty (CaseStatement a b) =
    pretty (simplify (CaseStatement a b))

data BinaryOp

data ComparisionOperator
  = ExtendsLeft
  | ExtendsRight
  | Equals
  | NotEquals
  deriving (Eq, Show)

data ObjectLiteralProperty = KeyValue
  { isReadonly :: Maybe Bool,
    isOptional :: Maybe Bool,
    key :: String,
    value :: Expression
  }
  deriving (Eq, Show)

instance Pretty ObjectLiteralProperty where
  pretty KeyValue {..} =
    (group readonly <> pretty key <> optional <> ":") <+> pretty value
    where
      readonly =
        case isReadonly of
          Just True -> "readonly" <> space
          Just False -> "-readonly" <> space
          Nothing -> emptyDoc
      optional =
        case isOptional of
          Just True -> "?"
          Just False -> "-?"
          Nothing -> emptyDoc

prettyOpList :: Expression -> Doc ann
prettyOpList a =
  group $ align $ enclose (flatAlt "( " "(") (flatAlt " )" ")") $ pretty a

never :: Expression
never = Identifier "never"
