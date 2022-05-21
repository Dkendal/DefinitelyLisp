{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.Foldable
import Data.Text
import Newtype.Parser
import Prettyprinter
import Prettyprinter.Render.Text (renderStrict)
import Test.Tasty
import Test.Tasty.HUnit
import Text.Megaparsec
import Prelude hiding (unlines)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "Pretty printing"
    [ testCase "empty program" $
        assertPretty
          pProgram
          "\n\n\n"
          "",
      testCase "Program" $
        assertPretty
          pProgram
          (unlines ["type A = 1", "type B = 2"])
          (here ["type A = 1", "type B = 2"]),
      testCase "Program with extra newlines at the start" $
        assertPretty
          pProgram
          (unlines [" ", "type A = 1", "type B = 2"])
          (here ["type A = 1", "type B = 2"]),
      testCase "Program with extra newlines at the end" $
        assertPretty
          pProgram
          (unlines ["type A = 1", "type B = 2", ""])
          (here ["type A = 1", "type B = 2"]),
      testCase "Program with extra newlines between" $
        assertPretty
          pProgram
          (unlines ["type A = 1", " ", "type B = 2"])
          (here ["type A = 1", "type B = 2"]),
      -- TODO refute
      -- testCase "type definition with no indent" $
      --   assertPretty
      --     pProgram
      --     "type A =\n\
      --     \1"
      --     "",
      testCase "type definition with indent after equals" $
        assertPretty
          pProgram
          (unlines ["type A =", "  1"])
          "type A = 1",
      testCase "type definition with indent before equals" $
        assertPretty
          pProgram
          (unlines ["type A", "  = 1"])
          "type A = 1",
      testCase "type definition must be indented" $
        assertParserError
          pProgram
          (unlines ["type A", "= 1"])
          ["incorrect indentation (got 1, should be greater than 1)\n"],
      testCase "type definition must be indented" $
        assertParserError
          pProgram
          (unlines ["type A =", "1"])
          ["incorrect indentation (got 1, should be greater than 1)\n"],
      -- TODO refute
      -- testCase "interface must be indent" $
      --   assertPretty
      --     (pStatement <* eof)
      --     "interface A where\n\
      --     \foo: 0\n\
      --     \bar: 1"
      --     "",
      testCase "expression" $
        assertPretty
          (pExpr <* eof)
          "A"
          "A",
      testCase "expression" $
        assertPretty
          (pExpr <* eof)
          "A 1"
          "A<1>",
      testCase "expression" $
        assertPretty
          (pExpr <* eof)
          "A 1 true {}"
          "A<1, true, {}>",
      testCase "expression" $
        assertPretty
          (pExpr <* eof)
          "A (B true) {}"
          "A<B<true>, {}>",
      testCase "expression" $
        assertPretty
          (pExpr <* eof)
          ((stripEnd . unlines) ["A", "  1", "  2"])
          "A<1, 2>",
      testCase "interface definition" $
        assertPretty
          (pStatement <* eof)
          ( unlines
              [ "interface A where",
                "  foo : 0",
                "  bar : 1"
              ]
          )
          ( here
              [ "interface A {",
                "  foo: 0;",
                "  bar: 1;",
                "}"
              ]
          ),
      testCase "if extends else then expression" $
        assertPretty
          (pExpr <* eof)
          "if LHS <: RHS then Then else Else"
          "LHS extends RHS ? Then : Else",
      testCase "if extends else then expression" $
        assertPretty
          (pExpr <* eof)
          "if LHS <: RHS then Then"
          "LHS extends RHS ? Then : never",
      testCase "if right-extends then expression" $
        assertPretty
          (pExpr <* eof)
          "if LHS :> RHS then Then"
          "RHS extends LHS ? Then : never",
      testCase "if expressions may be negated" $
        assertPretty
          (pExpr <* eof)
          "if not LHS <: RHS then Then"
          "LHS extends RHS ? never : Then",
      testCase "if with infer operator" $
        assertPretty
          (pExpr <* eof)
          "if Left <: Right ?Infer then Then"
          "Left extends Right<infer Infer> ? Then : never",
      testCase "comparision with complex term" $
        assertPretty
          (pExtendsExpr <* eof)
          "if A B (C D) <: 0 then 1"
          "A<B, C<D>> extends 0 ? 1 : never",
      testCase "case statement" $
        assertPretty
          (pExpr <* eof)
          ( unlines
              [ "case A of",
                " B -> B a a a",
                " C -> C a a a"
              ]
          )
          "A extends B ? B<a, a, a> : A extends C ? C<a, a, a> : never",
      testCase "case statement" $
        assertPretty
          (pExpr <* eof)
          ( unlines
              [ "case A of",
                " B ->",
                "   B a a a",
                " C ->",
                "   C a a a"
              ]
          )
          "A extends B ? B<a, a, a> : A extends C ? C<a, a, a> : never",
      testCase "case statement with fall through" $
        assertPretty
          (pExpr <* eof)
          ( unlines
              [ "case A of",
                " 0 -> 1",
                " _ -> 2"
              ]
          )
          "A extends 0 ? 1 : 2"
    ]

assertPretty ::
  (VisualStream s, TraversableStream s, ShowErrorComponent e, Pretty a) =>
  Parsec e s a ->
  s ->
  String ->
  IO ()
assertPretty parser input output =
  case parse parser "" input of
    Left a ->
      assertFailure (errorBundlePretty a)
    Right a ->
      unpack (renderStrict (layoutPretty (LayoutOptions Unbounded) (pretty a))) @?= output

assertParserError ::
  (VisualStream s, TraversableStream s, ShowErrorComponent e, Pretty a) =>
  Parsec e s a ->
  s ->
  [String] ->
  IO ()
assertParserError parser input expected =
  case parse parser "" input of
    Left (ParseErrorBundle s _) ->
      [parseErrorTextPretty e | e <- toList s] @?= expected
    Right _ ->
      assertFailure "expected parser error"

here :: [Text] -> String
here = unpack . stripEnd . unlines
