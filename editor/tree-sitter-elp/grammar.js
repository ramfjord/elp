/**
 * @file ELP grammar for tree-sitter
 * @license MIT
 *
 * Forked from tree-sitter-embedded-template. ELP supports a strict subset
 * of ERB's delimiters: <%, <%=, <%# with optional `-` open/close trim.
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

module.exports = grammar({
  name: 'elp',

  extras: _ => [],

  rules: {
    template: $ => repeat(choice(
      $.directive,
      $.output_directive,
      $.comment_directive,
      $.content,
    )),

    code: _ => repeat1(/[^%-]+|[%-]/),

    content: _ => prec.right(repeat1(/[^<]+|</)),

    directive: $ => seq(
      choice('<%', '<%-'),
      optional($.code),
      choice('%>', '-%>'),
    ),

    output_directive: $ => seq(
      choice('<%=', '<%-='),
      optional($.code),
      choice('%>', '-%>'),
    ),

    comment_directive: $ => seq(
      choice('<%#', '<%-#'),
      optional(alias($.code, $.comment)),
      choice('%>', '-%>'),
    ),
  },
});
