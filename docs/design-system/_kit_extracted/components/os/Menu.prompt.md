Glass popover menu for context menus and dropdowns. Pass `items` (each `{label, icon?, shortcut?, danger?, disabled?, separator?}`); position it yourself at the anchor.

```jsx
<Menu
  items={[
    { label: 'Open', icon: <i data-lucide="folder-open" />, shortcut: '↵' },
    { label: 'Rename', icon: <i data-lucide="pencil" />, shortcut: 'F2' },
    { separator: true },
    { label: 'Delete', icon: <i data-lucide="trash-2" />, danger: true, shortcut: '⌫' },
  ]}
  onSelect={(it) => console.log(it.label)}
/>
```
