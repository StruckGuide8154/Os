Square icon-only button for toolbars, titlebars and the dock; pass `active` for toggle state and always set `label` for accessibility.

```jsx
<IconButton icon={<i data-lucide="settings" />} label="Settings" />
<IconButton icon={<i data-lucide="wifi" />} tone="accent" active label="Network" />
<IconButton icon={<i data-lucide="x" />} tone="danger" size="sm" label="Close" />
```
