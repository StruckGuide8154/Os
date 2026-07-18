import React from 'react';

/**
 * Grit — Window
 * The redesigned application window: rounded 16px corners, a glass
 * titlebar with traffic-light controls, layered window shadow and a
 * lit top edge. Composes any content as children.
 */
export function Window({
  title = 'Untitled',
  icon = null,
  children,
  toolbar = null,        // optional node rendered as a sub-toolbar row
  width = 560,
  height,
  active = true,
  onClose,
  onMinimize,
  onMaximize,
  style,
  bodyStyle,
  ...rest
}) {
  return (
    <div
      style={{
        display: 'flex',
        flexDirection: 'column',
        width,
        height,
        background: 'var(--surface-window)',
        border: '1px solid',
        borderColor: active ? 'var(--border-control)' : 'var(--border)',
        borderRadius: 'var(--r-xl)',
        boxShadow: active ? 'var(--shadow-window)' : 'var(--shadow-md)',
        overflow: 'hidden',
        opacity: active ? 1 : 0.92,
        ...style,
      }}
      {...rest}
    >
      {/* Titlebar (glass) */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 12,
          height: 'var(--titlebar-h)',
          padding: '0 12px',
          background: 'var(--glass-tint)',
          backdropFilter: 'var(--blur-glass)',
          WebkitBackdropFilter: 'var(--blur-glass)',
          borderBottom: '1px solid var(--border)',
          boxShadow: 'var(--edge-light)',
          flex: '0 0 auto',
          userSelect: 'none',
        }}
      >
        {/* Traffic lights */}
        <div style={{ display: 'flex', gap: 8, flex: '0 0 auto' }}>
          <Light color="#FF6B70" onClick={onClose} />
          <Light color="#FFC754" onClick={onMinimize} />
          <Light color="var(--sage-base)" onClick={onMaximize} />
        </div>
        {/* Title */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, flex: 1, justifyContent: 'center', minWidth: 0 }}>
          {icon && <span style={{ display: 'inline-flex', width: 15, height: 15, color: 'var(--text-muted)' }}>{icon}</span>}
          <span style={{
            font: 'var(--fw-semibold) var(--fs-sm)/1 var(--font-ui)',
            color: active ? 'var(--text-heading)' : 'var(--text-muted)',
            whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
          }}>{title}</span>
        </div>
        <div style={{ width: 52, flex: '0 0 auto' }} />
      </div>

      {toolbar && (
        <div style={{
          display: 'flex', alignItems: 'center', gap: 8,
          padding: '8px 12px',
          borderBottom: '1px solid var(--border)',
          background: 'var(--surface-panel)',
          flex: '0 0 auto',
        }}>{toolbar}</div>
      )}

      <div style={{ flex: 1, minHeight: 0, overflow: 'auto', ...bodyStyle }}>
        {children}
      </div>
    </div>
  );
}

function Light({ color, onClick }) {
  const [hover, setHover] = React.useState(false);
  return (
    <span
      onClick={onClick}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        width: 12, height: 12, borderRadius: '50%',
        background: color,
        boxShadow: hover ? `0 0 0 1px rgba(255,255,255,0.25), 0 0 8px ${color}` : 'inset 0 0 0 1px rgba(0,0,0,0.15)',
        cursor: 'pointer',
        transition: 'box-shadow var(--dur-2) var(--ease-out)',
      }}
    />
  );
}
