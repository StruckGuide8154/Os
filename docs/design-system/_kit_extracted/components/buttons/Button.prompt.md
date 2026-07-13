Grit button — the standard clickable action; use `primary` for the single main action in a view and `secondary`/`ghost` for everything else.

```jsx
<Button variant="primary" icon={<i data-lucide="rocket" />}>Launch</Button>
<Button>Cancel</Button>
<Button variant="ghost" size="sm">Details</Button>
<Button variant="danger" icon={<i data-lucide="trash-2" />}>Delete</Button>
```

Variants: `primary` (neon gradient + glow), `secondary` (raised surface, default), `ghost` (transparent → accent tint on hover), `danger`. Sizes: `sm` | `md` | `lg`. Supports `icon`, `trailingIcon`, `block`, `disabled`.
