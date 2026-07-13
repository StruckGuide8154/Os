import React from 'react';

/**
 * Grit — Input
 * Inset field on the surface ramp. Focus lights the neon ring.
 * Optional leading/trailing icon slots; supports an error state.
 */
export function Input({
  value,
  defaultValue,
  placeholder,
  type = 'text',
  size = 'md',          // 'sm' | 'md' | 'lg'
  icon = null,
  trailing = null,
  invalid = false,
  disabled = false,
  block = true,
  onChange,
  style,
  ...rest
}) {
  const [focus, setFocus] = React.useState(false);
  const [hover, setHover] = React.useState(false);

  const sizes = {
    sm: { h: 'var(--ctl-h-sm)', fs: 'var(--fs-xs)', px: 10 },
    md: { h: 'var(--ctl-h-md)', fs: 'var(--fs-sm)', px: 12 },
    lg: { h: 'var(--ctl-h-lg)', fs: 'var(--fs-base)', px: 14 },
  };
  const s = sizes[size] || sizes.md;
  const iconSize = size === 'lg' ? 18 : 16;

  const borderColor = invalid
    ? 'var(--grit-error)'
    : focus ? 'var(--accent)' : (hover ? 'var(--border-strong)' : 'var(--border-control)');

  return (
    <div
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        display: block ? 'flex' : 'inline-flex',
        width: block ? '100%' : 'auto',
        alignItems: 'center',
        gap: 8,
        height: s.h,
        padding: `0 ${s.px}px`,
        background: 'var(--surface-input)',
        border: '1px solid',
        borderColor,
        borderRadius: 'var(--r-sm)',
        boxShadow: invalid
          ? '0 0 0 3px var(--grit-error-soft)'
          : (focus ? 'var(--ring)' : 'inset 0 1px 2px rgba(0,0,0,0.30)'),
        transition: 'border-color var(--dur-2) var(--ease-out), box-shadow var(--dur-2) var(--ease-out)',
        opacity: disabled ? 0.5 : 1,
        cursor: disabled ? 'not-allowed' : 'text',
        ...style,
      }}
    >
      {icon && (
        <span style={{ display: 'inline-flex', flex: '0 0 auto', width: iconSize, height: iconSize, color: focus ? 'var(--text-accent)' : 'var(--text-muted)' }}>
          {icon}
        </span>
      )}
      <input
        value={value}
        defaultValue={defaultValue}
        placeholder={placeholder}
        type={type}
        disabled={disabled}
        onChange={onChange}
        onFocus={() => setFocus(true)}
        onBlur={() => setFocus(false)}
        style={{
          flex: 1,
          minWidth: 0,
          height: '100%',
          border: 'none',
          outline: 'none',
          background: 'transparent',
          color: 'var(--text-heading)',
          font: `var(--fw-regular) ${s.fs}/1 var(--font-ui)`,
          letterSpacing: '0.01em',
        }}
        {...rest}
      />
      {trailing && <span style={{ display: 'inline-flex', flex: '0 0 auto', color: 'var(--text-muted)' }}>{trailing}</span>}
    </div>
  );
}
