use node::Bindings;
use pretty::RcDoc as D;
use serde::Serialize;

use super::*;

use std::collections::HashMap;

#[derive(Debug, PartialEq, Eq, Clone, Serialize)]
#[serde(rename_all = "kebab-case")]
pub struct LetExpr<'a> {
    #[serde(skip)]
    pub span: Span<'a>,
    pub bindings: Bindings<'a>,
    pub body: Node<'a>,
}

impl<'a> LetExpr<'a> {
    pub fn map<F>(&self, f: F) -> Self
    where
        F: Fn(&Node<'a>) -> Node<'a>,
    {
        let mut expr = self.clone();
        expr.body = f(&self.body);
        expr
    }
    /// Replace all identifiers in the body of the let expression with their corresponding
    /// values
    pub fn simplify(&self) -> super::node::Node<'a> {
        let mut bindings = self.bindings.clone();
        // simplifiy all bindings first
        for (ident, value) in &self.bindings {
            let new_value = value.simplify();
            bindings.insert(ident.clone(), new_value);
        }

        let (tree, _) = self
            .body
            .prewalk(bindings, &|node, bindings| match &*node.value {
                Ast::Ident(id) => {
                    let new_value = bindings.get(&id.name).unwrap_or(&node).clone();
                    (new_value, bindings)
                }
                _ => (node, bindings),
            });

        tree
    }
}
