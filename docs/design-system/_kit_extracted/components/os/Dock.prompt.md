The redesigned taskbar — a floating glass dock. Pass `items` (each `{id, icon, label, active, running}`); handle clicks via `onItemClick(id)`.

```jsx
<Dock
  items={[
    { id: 'files', icon: <i data-lucide="folder" />, label: 'Files', active: true, running: true },
    { id: 'term',  icon: <i data-lucide="square-terminal" />, label: 'Terminal', running: true },
    { id: 'settings', icon: <i data-lucide="settings" />, label: 'Settings' },
  ]}
  onItemClick={open}
/>
```
