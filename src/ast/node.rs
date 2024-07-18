use super::*;
use pest::Span;
use std::collections::HashMap;

#[derive(Debug, PartialEq, Eq, Clone)]
pub struct Node<'a> {
    /// Generated nodes have no span
    pub span: Option<Span<'a>>,
    pub value: Box<Ast<'a>>,
}

impl<'a> serde::Serialize for Node<'a> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        self.value.serialize(serializer)
    }
}

impl<'a> From<Ast<'a>> for Node<'a> {
    fn from(v: Ast<'a>) -> Self {
        Self::generate(Box::new(v))
    }
}

impl<'a> Node<'a> {
    pub fn from_pair<R>(pair: &pest::iterators::Pair<'a, R>, value: Ast<'a>) -> Self
    where
        R: pest::RuleType,
    {
        Self {
            span: Some(pair.clone().as_span()),
            value: Box::new(value),
        }
    }

    pub fn from_span(span: Span<'a>, value: Ast<'a>) -> Self {
        Self {
            span: Some(span),
            value: Box::new(value),
        }
    }

    pub fn generate(value: Box<Ast<'a>>) -> Self {
        Self { span: None, value }
    }

    /// Transform the value of the node with a function that takes a reference to the value
    pub fn map(&self, f: impl Fn(&Ast<'a>) -> Ast<'a>) -> Self {
        Self {
            span: self.span,
            value: Box::new(f(&self.value)),
        }
    }

    /// Replace the value of the node with a new value, creating a new node
    /// with the same span.
    pub fn replace(self, value: Ast<'a>) -> Self {
        Self {
            span: self.span,
            value: Box::new(value),
        }
    }

    pub(crate) fn new(span: Option<Span<'a>>, value: Ast<'a>) -> Self {
        Self {
            span,
            value: Box::new(value),
        }
    }

    pub fn set_span(&mut self, span: Option<Span<'a>>) {
        self.span = span;
    }

    pub fn set_value(&mut self, value: Box<Ast<'a>>) {
        self.value = value;
    }

    pub fn prewalk<Context, F>(&self, ctx: Context, pre: &F) -> (Self, Context)
    where
        Context: Clone,
        F: Fn(Self, Context) -> (Self, Context),
    {
        self.traverse(ctx, pre, &|n, c| (n, c))
    }

    pub fn postwalk<Context, F>(&self, ctx: Context, post: &F) -> (Self, Context)
    where
        Context: Clone,
        F: Fn(Self, Context) -> (Self, Context),
    {
        self.traverse(ctx, &|n, c| (n, c), post)
    }

    pub fn traverse<Context, Pre, Post>(
        &self,
        ctx: Context,
        pre: &Pre,
        post: &Post,
    ) -> (Self, Context)
    where
        Context: Clone,
        Pre: Fn(Self, Context) -> (Self, Context),
        Post: Fn(Self, Context) -> (Self, Context),
    {
        /// Extract the node from the tuple
        pub(crate) fn pick_node<T>((node, _ctx): (Node, T)) -> Node {
            node
        }

        // Produce a new node and context
        let result = |node: Ast<'a>, ctx: Context| (self.clone().replace(node), ctx);

        // Reducer
        let red = move |node: &Node<'a>, ctx| node.traverse(ctx, pre, post);

        // Reducer only returns the node, drops the context
        let red_pick_node = move |node: &Node<'a>, ctx| pick_node(node.traverse(ctx, pre, post));

        // Reducer that maps over a list of nodes
        let red_items = move |node: &Nodes<'a>, ctx: Context| {
            node.iter()
                .map(|item| red_pick_node(item, ctx.clone()))
                .collect_vec()
        };

        // Returns a closure that takes a node
        let fn_red_pick_node =
            move |ctx| move |node: &Node<'a>| pick_node(node.traverse(ctx, pre, post));

        let node = self.clone();

        let (node, ctx) = pre(node, ctx);

        let (node, ctx) = match &*node.value {
            Ast::Access { lhs, rhs, is_dot } => {
                let (lhs, _) = red(lhs, ctx.clone());
                let (rhs, _) = red(rhs, ctx.clone());

                let ast = Ast::Access {
                    lhs,
                    rhs,
                    is_dot: *is_dot,
                };

                (self.clone().replace(ast), ctx)
            }
            Ast::Application(Application { name, args }) => {
                let ast = Ast::Application(Application {
                    name: name.clone(),
                    args: red_items(args, ctx.clone()),
                });

                result(ast, ctx)
            }

            Ast::Array(inner) => {
                let (inner, _) = red(inner, ctx.clone());
                let ast = Ast::Array(inner);
                result(ast, ctx)
            }

            Ast::InfixOp { lhs, op, rhs } => {
                let ast = Ast::InfixOp {
                    lhs: red_pick_node(lhs, ctx.clone()),
                    op: op.clone(),
                    rhs: red_pick_node(rhs, ctx.clone()),
                };

                result(ast, ctx)
            }

            Ast::Builtin { name, argument } => {
                let (argument, _) = red(argument, ctx.clone());

                let ast = Ast::Builtin {
                    name: name.clone(),
                    argument,
                };

                result(ast, ctx)
            }

            Ast::CondExpr(cond_expr::Expr { arms, else_arm }) => {
                let arms = arms
                    .iter()
                    .map(|arm| {
                        let mut arm = arm.clone();
                        arm.condition = red_pick_node(&arm.condition, ctx.clone());
                        arm.body = red_pick_node(&arm.body, ctx.clone());
                        arm
                    })
                    .collect_vec();

                let else_arm = red_pick_node(else_arm, ctx.clone());

                let ast = Ast::CondExpr(cond_expr::Expr { arms, else_arm });

                result(ast, ctx)
            }

            Ast::ExtendsInfixOp { lhs, op, rhs } => {
                let (lhs, _) = red(lhs, ctx.clone());
                let (rhs, _) = red(rhs, ctx.clone());

                let ast = Ast::ExtendsInfixOp {
                    lhs,
                    op: op.clone(),
                    rhs,
                };

                (self.clone().replace(ast), ctx)
            }

            Ast::ExtendsExpr(ExtendsExpr {
                lhs,
                rhs,
                then_branch,
                else_branch,
            }) => {
                let lhs = red_pick_node(lhs, ctx.clone());
                let rhs = red_pick_node(rhs, ctx.clone());
                let then_branch = red_pick_node(then_branch, ctx.clone());
                let else_branch = red_pick_node(else_branch, ctx.clone());

                let ast = Ast::ExtendsExpr(ExtendsExpr {
                    lhs,
                    rhs,
                    then_branch,
                    else_branch,
                });
                result(ast, ctx)
            }

            Ast::ExtendsPrefixOp { op, value } => {
                let value = red_pick_node(value, ctx.clone());

                let ast = Ast::ExtendsPrefixOp {
                    op: op.clone(),
                    value,
                };

                result(ast, ctx)
            }

            Ast::IfExpr(if_expr::Expr {
                condition,
                then_branch,
                else_branch,
            }) => {
                let (condition, _) = red(condition, ctx.clone());
                let (then_branch, _) = red(then_branch, ctx.clone());
                let else_branch = else_branch.as_ref().map(fn_red_pick_node(ctx.clone()));

                let ast = Ast::IfExpr(if_expr::Expr {
                    condition,
                    then_branch,
                    else_branch,
                });

                (self.clone().replace(ast), ctx)
            }

            Ast::ImportStatement {
                import_clause,
                module,
            } => {
                let ast = Ast::ImportStatement {
                    import_clause: import_clause.clone(),
                    module: module.clone(),
                };

                result(ast, ctx)
            }
            Ast::LetExpr(let_expr) => {
                let (body, _) = red(&let_expr.body, ctx.clone());

                let ast = Ast::LetExpr(let_expr::Expr {
                    bindings: let_expr.bindings.clone(),
                    body,
                });

                result(ast, ctx)
            }
            Ast::MappedType(MappedType {
                index,
                iterable,
                remapped_as,
                readonly_mod,
                optional_mod,
                body,
            }) => {
                let (iterable, _) = red(iterable, ctx.clone());
                let remapped_as = remapped_as.as_ref().map(fn_red_pick_node(ctx.clone()));
                let body = red_pick_node(body, ctx.clone());

                let ast = Ast::MappedType(MappedType {
                    index: index.clone(),
                    iterable,
                    remapped_as,
                    readonly_mod: readonly_mod.clone(),
                    optional_mod: optional_mod.clone(),
                    body,
                });

                result(ast, ctx)
            }
            Ast::MatchExpr(match_expr::Expr {
                value,
                arms,
                else_arm,
            }) => {
                let (value, _) = red(value, ctx.clone());

                let arms = arms
                    .iter()
                    .map(|arm| {
                        let mut arm = arm.clone();
                        arm.pattern = red_pick_node(&arm.pattern, ctx.clone());
                        arm.body = red_pick_node(&arm.body, ctx.clone());
                        arm
                    })
                    .collect_vec();

                let else_arm = red_pick_node(else_arm, ctx.clone());

                let ast = Ast::MatchExpr(match_expr::Expr {
                    value,
                    arms,
                    else_arm,
                });

                result(ast, ctx)
            }
            Ast::NamespaceAccess(access) => {
                let lhs = red_pick_node(&access.lhs, ctx.clone());
                let rhs = red_pick_node(&access.rhs, ctx.clone());

                let ast = Ast::NamespaceAccess(NamespaceAccess { lhs, rhs });

                result(ast, ctx)
            }
            Ast::ObjectLiteral(object) => {
                let properties = object
                    .properties
                    .iter()
                    .map(|prop| {
                        let mut prop = prop.clone();
                        prop.value = red_pick_node(&prop.value, ctx.clone());
                        prop
                    })
                    .collect_vec();

                let ast = Ast::ObjectLiteral(ObjectLiteral { properties });

                result(ast, ctx)
            }
            Ast::Program(statements) => {
                let mut ctx = ctx.clone();
                let mut statements = statements.clone();

                for statement in &mut statements {
                    (*statement, ctx) = red(statement, ctx.clone());
                }

                let ast = Ast::Program(statements);

                result(ast, ctx)
            }
            Ast::Statement(inner) => {
                // Statement MAY propagate context to siblings
                let (inner, ctx) = red(inner, ctx.clone());
                let ast = Ast::Statement(inner);
                result(ast, ctx)
            }
            node @ Ast::TemplateString(_) => result(node.clone(), ctx.clone()),
            Ast::Tuple(Tuple { items }) => {
                let items = items
                    .iter()
                    .map(|item| red_pick_node(item, ctx.clone()))
                    .collect_vec();

                let ast = Ast::Tuple(Tuple { items });

                result(ast, ctx)
            }
            Ast::TypeAlias {
                export,
                name,
                params,
                body,
            } => {
                let (body, _) = body.traverse(ctx.clone(), pre, post);

                let params = params
                    .iter()
                    .map(
                        |TypeParameter {
                             name: param_name,
                             constraint,
                             default,
                             rest,
                         }| {
                            let constraint = constraint.as_ref().map(fn_red_pick_node(ctx.clone()));
                            let default = default.as_ref().map(fn_red_pick_node(ctx.clone()));

                            TypeParameter {
                                name: param_name.clone(),
                                constraint,
                                default,
                                rest: *rest,
                            }
                        },
                    )
                    .collect_vec();

                let ast = Ast::TypeAlias {
                    export: *export,
                    name: name.clone(),
                    params,
                    body,
                };

                result(ast, ctx)
            }
            _ => (node, ctx),
        };

        let (node, acc) = post(node, ctx);

        (node, acc)
    }

    pub fn simplify(&self) -> Self {
        let bindings: Bindings = Default::default();
        let (tree, _) = self.traverse(
            bindings,
            &|node, ctx| (node, ctx),
            &|node, ctx| match &*node.value {
                Ast::IfExpr(if_expr) => (if_expr.simplify(), ctx),
                Ast::MatchExpr(match_expr) => (match_expr.simplify(), ctx),
                Ast::CondExpr(cond_expr) => (cond_expr.simplify(), ctx),
                Ast::LetExpr(let_expr) => (let_expr.simplify(), ctx),
                _ast => (node, ctx),
            },
        );
        tree
    }

    pub fn eval(&self) -> Self {
        let (tree, _) = self.prewalk((), &|node, ctx| match &*node.value {
            Ast::MacroCall(value) => (value.eval(), ctx),
            _ => (node, ctx),
        });

        tree
    }

    pub(crate) fn is_extension(&self, other: &Self) -> bool {
        self.value.as_ref().is_extension(&other.value)
    }
}

pub(crate) type Nodes<'a> = Vec<Node<'a>>;

pub(crate) type Bindings<'a> = HashMap<Identifier, Node<'a>>;

impl<'a> Default for Node<'a> {
    fn default() -> Self {
        Node {
            span: None,
            value: Box::new(Ast::NoOp),
        }
    }
}

impl<'a> typescript::Pretty for Node<'a> {
    fn to_ts(&self) -> pretty::RcDoc<()> {
        self.value.to_ts()
    }
}

impl<'a> PrettySexpr for Node<'a> {
    fn pretty_sexpr(&self) -> D {
        self.value.pretty_sexpr()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{parser::Rule, test_support::*};
    use pretty_assertions::assert_eq;

    #[test]
    fn is_extension() {
        assert_eq!(ast!("1").is_extension(&ast!("number")), true)
    }
}
