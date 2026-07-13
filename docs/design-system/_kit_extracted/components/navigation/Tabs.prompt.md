Segmented control / tab switcher. Controlled via `value` + `onChange(id)`.

```jsx
<Tabs value={tab} onChange={setTab} items={[
  { id: 'general', label: 'General', icon: <i data-lucide="sliders-horizontal" /> },
  { id: 'network', label: 'Network', icon: <i data-lucide="wifi" /> },
]} />
```
