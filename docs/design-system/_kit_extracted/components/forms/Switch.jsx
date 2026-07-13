import React from 'react';

/**
 * Grit — Switch
 * Pill toggle. On state fills with the accent gradient + soft glow.
 */
export function Switch({
  checked = false,
  disabled = false,
  size = 'md',          // 'sm' | 'md'
  onChange,
  label,
  style,
  ...rest
}) {
  const dims = size === 'sm'
    ? { w: 34, h: 20, knob: 14, pad: 3 }
    : { w: 42, h: 24, knob: 18, pad: 3 };
  const x = checked ? dims.w - dims.knob - dims.pad : dims.pad;

  const track = (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled}
      onClick={() => !disabled && onChange && onChange(!checked)}
      style={{
        position: 'relative',
        width: dims.w,
        height: dims.h,
        flex: '0 0 auto',
        borderRadius: 'var(--r-pill)',
        border: '1px solid',
        borderColor: checked ? 'transparent' : 'var(--border-strong)',
        background: checked ? 'var(--accent-grad)' : 'var(--surface-input)',
        boxShadow: checked ? 'var(--glow-soft)' : 'inset 0 1px 2px rgba(0,0,0,0.35)',
        cursor: disabled ? 'not-allowed' : 'pointer',
        opacity: disabled ? 0.5 : 1,
        transition: 'background var(--dur-3) var(--ease-out), border-color var(--dur-3) var(--ease-out), box-shadow var(--dur-3) var(--ease-out)',
        padding: 0,
      }}
      {...rest}
    >
      <span
        style={{
          position: 'absolute',
          top: dims.pad,
          left: x,
          width: dims.knob,
          height: dims.knob,
          borderRadius: '50%',
          background: checked ? '#fff' : '#C5CCD8',
          boxShadow: '0 1px 3px rgba(0,0,0,0.45)',
          transition: 'left var(--dur-3) var(--ease-spring)',
        }}
      />
    </button>
  );

  if (!label) return track;
  return (
    <label style={{ display: 'inline-flex', alignItems: 'center', gap: 10, cursor: disabled ? 'not-allowed' : 'pointer', ...style }}>
      {track}
      <span style={{ font: 'var(--fw-medium) var(--fs-sm)/1 var(--font-ui)', color: 'var(--text-body)' }}>{label}</span>
    </label>
  );
}
