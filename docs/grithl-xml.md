# GritHL XML Support

GritOS exposes a small XML 1.0 DOM parser to user apps through
`src/user/grithl/lib/xml.ghl`. It is designed for trusted local documents such
as SVG assets, app metadata, and simple configuration files.

## API

```ghl
xml_parse(buf, len)
xml_root()
xml_tag(node)
xml_tag_name(node, out, max)
xml_first_child(node)
xml_next_sibling(node)
xml_parent(node)
xml_attr(node, name, nlen, out, omax)
xml_text(node, out, max)
xml_free()
xml_last_error()
xml_last_error_code()
xml_last_error_offset()
xml_node_count()
xml_text_runs(node)
xml_text_run(node, index, out, max)
xml_namespace(node, prefix, prefix_len, out, max)
xml_node_namespace(node, out, max)
xml_entity_value(name, name_len, out, max)
```

`xml_last_error()` returns a packed value:

- bits 31..0: `XML_ERR_*`
- bits 63..32: byte offset of the parse failure

Convenience walking helpers in `xml.ghl`:

```ghl
xml_first_child_safe(node)
xml_next_sibling_safe(node)
xml_next_child(parent, child)
xml_tag_is(node, tag_id)
xml_same_tag(a, b)
```

These helpers normalize negative node handles to `XML_NIL` and keep child
iteration from walking outside the expected parent. The tag-id helpers compare
interned parser tag ids, so callers that already have an expected id can avoid
copying names into scratch buffers for repeated tag checks.

`xml_text(node, ...)` is the simple text accessor for direct element text.
Mixed-content callers should use `xml_text_runs(node)` and
`xml_text_run(node, index, out, max)` to walk each text segment between child
elements. Run `0` is the text before the first child, run `1` is between the
first and second child, and so on. CDATA-only runs are returned without the
CDATA wrapper.

`xml_namespace()` resolves `xmlns` attributes from a node through its
ancestors. Pass a zero `prefix_len` for the default namespace.
`xml_node_namespace()` resolves the namespace URI for a node's own tag prefix.
`xml_entity_value()` copies replacement text for custom internal-DTD
`<!ENTITY ...>` declarations recorded during the last parse.

## Capacities

The parser uses one fixed kernel arena:

| Capacity | Limit |
| --- | --- |
| XML_MAX_NODES | 8192 |
| XML_MAX_ATTRS | 8192 |
| XML_STR_SIZE | 262144 bytes |
| XML_NAMES_SIZE | 16384 bytes |
| XML_MAX_NAMES | 1024 |
| XML_MAX_DEPTH | 64 |

Single live document behavior is intentional: a successful `xml_parse()`
replaces the previous tree, and `xml_free()` clears the arena. Apps that need
two documents must copy out the data they need before parsing the next one.

## Support Matrix

| Area | Status | Notes |
| --- | --- | --- |
| Elements | Supported | Nested elements up to parser depth limit. |
| Attributes | Supported | Single-quoted and double-quoted values. |
| Text nodes | Supported | `xml_text(node, ...)` copies simple direct element text; mixed content can be walked with `xml_text_runs` / `xml_text_run`. |
| Comments | Supported | Skipped during parse. |
| CDATA | Supported | Parsed into text storage. |
| Processing instructions | Supported subset | XML prolog and other PIs are skipped. |
| Predefined entities | Supported | `lt`, `gt`, `amp`, `quot`, `apos`. |
| Numeric entities | Supported | Decimal and hex numeric entities. |
| Custom internal entities | Supported subset | Internal `<!ENTITY name "value">` definitions are recorded and resolved; values are available through `xml_entity_value`. |
| Error diagnostics | Supported | Exposed through `xml_last_error*` wrappers. |
| Node count | Supported | Exposed through `xml_node_count`. |
| Mixed text runs | Supported | Exposed through `xml_text_runs` / `xml_text_run` for public mixed-content traversal. |
| Namespaces | Supported subset | Prefixes are preserved in names; `xmlns` URI lookup is exposed through namespace helpers. |
| DTD | Supported subset | Internal subsets may define custom entities; declarations such as `<!ELEMENT ...>` are skipped. |
| External entities | Not implemented | Deliberately omitted for safety. |
| Multiple live docs | Not implemented | Single global parser arena; parse/free replaces the live document. |
| Streaming parse | Not implemented | Parser is one-shot over a complete buffer. |
| XPath/query language | Not implemented | Walk nodes with first-child/next-sibling. |

## Maintenance Rules

- Keep the kernel parser non-networked and entity-limited. Do not add external
  entity loading.
- Keep user-facing helpers in `xml.ghl` thin; expensive query helpers should be
  opt-in libraries so small apps do not inherit them.
- Any new syscall must validate app-owned buffers before touching parser output.
- Parser self-tests in `xml_self_test`, host fixtures in `tests/xml`, and the
  GritHL diagnostic smoke in `tests/ghl/xml_diag_smoke.ghl` must be updated
  when adding syntax.
- SVG support should use the public XML API, not parser internals.
