The redesigned application window shell — glass titlebar with traffic-light controls, rounded corners, layered shadow. Put app content in `children`; use `toolbar` for an app toolbar row.

```jsx
<Window title="Files" icon={<i data-lucide="folder" />} width={640} height={420}
        toolbar={<Button size="sm" variant="ghost" icon={<i data-lucide="plus"/>}>New</Button>}>
  …content…
</Window>
```

Pass `active={false}` for background/unfocused windows. Wire `onClose`/`onMinimize`/`onMaximize` to the traffic lights.
