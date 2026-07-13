/* @ds-bundle: {"format":3,"namespace":"NexusOSDesignSystem_497743","components":[{"name":"Button","sourcePath":"components/buttons/Button.jsx"},{"name":"IconButton","sourcePath":"components/buttons/IconButton.jsx"},{"name":"Avatar","sourcePath":"components/data/Avatar.jsx"},{"name":"Badge","sourcePath":"components/data/Badge.jsx"},{"name":"Card","sourcePath":"components/data/Card.jsx"},{"name":"ProgressBar","sourcePath":"components/data/ProgressBar.jsx"},{"name":"Checkbox","sourcePath":"components/forms/Checkbox.jsx"},{"name":"Input","sourcePath":"components/forms/Input.jsx"},{"name":"Slider","sourcePath":"components/forms/Slider.jsx"},{"name":"Switch","sourcePath":"components/forms/Switch.jsx"},{"name":"Tabs","sourcePath":"components/navigation/Tabs.jsx"},{"name":"Dock","sourcePath":"components/os/Dock.jsx"},{"name":"Menu","sourcePath":"components/os/Menu.jsx"},{"name":"Window","sourcePath":"components/os/Window.jsx"}],"sourceHashes":{"components/buttons/Button.jsx":"f48ba2ffb05b","components/buttons/IconButton.jsx":"5743c7fc2ca6","components/data/Avatar.jsx":"f608cddb8036","components/data/Badge.jsx":"8c2aad638d01","components/data/Card.jsx":"8191d26466ec","components/data/ProgressBar.jsx":"745a185cc118","components/forms/Checkbox.jsx":"df2a70bb94da","components/forms/Input.jsx":"7ef223457e33","components/forms/Slider.jsx":"07da733968d3","components/forms/Switch.jsx":"3427874efe30","components/navigation/Tabs.jsx":"3b07b3ea22e4","components/os/Dock.jsx":"7bd0ae17fdf5","components/os/Menu.jsx":"7181c572cd17","components/os/Window.jsx":"7af64b66c0df","ui_kits/desktop/Desktop.jsx":"b6bdbf5b7aee","ui_kits/desktop/apps.jsx":"2289d83cfb1e"},"inlinedExternals":[],"unexposedExports":[]} */

(() => {

const __ds_ns = (window.NexusOSDesignSystem_497743 = window.NexusOSDesignSystem_497743 || {});

const __ds_scope = {};

(__ds_ns.__errors = __ds_ns.__errors || []);

// components/buttons/Button.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * Grit — Button
 * Primary action uses the neon accent gradient with a soft glow.
 * Secondary/ghost/danger map onto the layered surface ramp.
 */
function Button({
  children,
  variant = 'secondary',
  // 'primary' | 'secondary' | 'ghost' | 'danger'
  size = 'md',
  // 'sm' | 'md' | 'lg'
  icon = null,
  // leading node (e.g. <Icon/>)
  trailingIcon = null,
  disabled = false,
  block = false,
  type = 'button',
  onClick,
  style,
  ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const [active, setActive] = React.useState(false);
  const [focus, setFocus] = React.useState(false);
  const sizes = {
    sm: {
      h: 'var(--ctl-h-sm)',
      px: '10px',
      fs: 'var(--fs-xs)',
      gap: '6px',
      r: 'var(--r-sm)'
    },
    md: {
      h: 'var(--ctl-h-md)',
      px: '14px',
      fs: 'var(--fs-sm)',
      gap: '8px',
      r: 'var(--r-sm)'
    },
    lg: {
      h: 'var(--ctl-h-lg)',
      px: '20px',
      fs: 'var(--fs-base)',
      gap: '9px',
      r: 'var(--r-md)'
    }
  };
  const s = sizes[size] || sizes.md;
  const base = {
    display: block ? 'flex' : 'inline-flex',
    width: block ? '100%' : 'auto',
    alignItems: 'center',
    justifyContent: 'center',
    gap: s.gap,
    height: s.h,
    padding: `0 ${s.px}`,
    borderRadius: s.r,
    font: `var(--fw-medium) ${s.fs}/1 var(--font-ui)`,
    letterSpacing: '0.01em',
    cursor: disabled ? 'not-allowed' : 'pointer',
    opacity: disabled ? 0.45 : 1,
    border: '1px solid transparent',
    transition: 'background var(--dur-2) var(--ease-out), border-color var(--dur-2) var(--ease-out), box-shadow var(--dur-2) var(--ease-out), transform var(--dur-1) var(--ease-out)',
    transform: active && !disabled ? 'translateY(0.5px) scale(0.985)' : 'none',
    userSelect: 'none',
    whiteSpace: 'nowrap'
  };
  const variants = {
    primary: {
      background: hover && !disabled ? 'var(--accent-hover)' : 'var(--accent-grad)',
      color: 'var(--on-accent)',
      fontWeight: 'var(--fw-semibold)',
      boxShadow: focus ? 'var(--glow-accent)' : hover ? 'var(--glow-soft), var(--edge-light)' : '0 2px 10px -2px var(--focus-ring), var(--edge-light)'
    },
    secondary: {
      background: active ? 'var(--surface-active)' : hover ? 'var(--surface-raised)' : 'var(--surface-panel)',
      color: 'var(--text-heading)',
      borderColor: hover ? 'var(--border-strong)' : 'var(--border-control)',
      boxShadow: focus ? 'var(--ring)' : 'var(--shadow-xs)'
    },
    ghost: {
      background: active ? 'var(--surface-raised)' : hover ? 'var(--accent-fill)' : 'transparent',
      color: hover ? 'var(--text-accent)' : 'var(--text-body)',
      borderColor: 'transparent',
      boxShadow: focus ? 'var(--ring)' : 'none'
    },
    danger: {
      background: hover && !disabled ? '#D98079' : 'var(--grit-error)',
      color: '#FBF1F0',
      fontWeight: 'var(--fw-semibold)',
      boxShadow: focus ? '0 0 0 3px rgba(207,111,102,0.40)' : '0 2px 10px -2px rgba(207,111,102,0.40)'
    }
  };
  return /*#__PURE__*/React.createElement("button", _extends({
    type: type,
    disabled: disabled,
    onClick: onClick,
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => {
      setHover(false);
      setActive(false);
    },
    onMouseDown: () => setActive(true),
    onMouseUp: () => setActive(false),
    onFocus: () => setFocus(true),
    onBlur: () => setFocus(false),
    style: {
      ...base,
      ...variants[variant],
      ...style
    }
  }, rest), icon && /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-flex',
      flex: '0 0 auto'
    }
  }, icon), children && /*#__PURE__*/React.createElement("span", null, children), trailingIcon && /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-flex',
      flex: '0 0 auto'
    }
  }, trailingIcon));
}
Object.assign(__ds_scope, { Button });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/buttons/Button.jsx", error: String((e && e.message) || e) }); }

// components/buttons/IconButton.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * Grit — IconButton
 * Square, icon-only control for toolbars, titlebars and the dock.
 * `tone="accent"` lights it with the neon tint.
 */
function IconButton({
  icon,
  size = 'md',
  // 'sm' | 'md' | 'lg'
  tone = 'neutral',
  // 'neutral' | 'accent' | 'danger'
  active = false,
  disabled = false,
  label,
  // aria-label (recommended)
  onClick,
  style,
  ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const [press, setPress] = React.useState(false);
  const sizes = {
    sm: 28,
    md: 34,
    lg: 42
  };
  const dim = sizes[size] || sizes.md;
  const toneColor = {
    neutral: {
      fg: 'var(--text-body)',
      fgHover: 'var(--text-heading)',
      bgHover: 'var(--surface-raised)'
    },
    accent: {
      fg: 'var(--text-accent)',
      fgHover: 'var(--text-accent)',
      bgHover: 'var(--accent-fill)'
    },
    danger: {
      fg: 'var(--grit-error)',
      fgHover: '#D98079',
      bgHover: 'var(--grit-error-soft)'
    }
  }[tone];
  return /*#__PURE__*/React.createElement("button", _extends({
    type: "button",
    "aria-label": label,
    "aria-pressed": active,
    disabled: disabled,
    onClick: onClick,
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => {
      setHover(false);
      setPress(false);
    },
    onMouseDown: () => setPress(true),
    onMouseUp: () => setPress(false),
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      width: dim,
      height: dim,
      borderRadius: 'var(--r-sm)',
      border: '1px solid',
      borderColor: active ? 'var(--border-control)' : 'transparent',
      background: active ? 'var(--accent-fill)' : hover ? toneColor.bgHover : 'transparent',
      color: active ? 'var(--text-accent)' : hover ? toneColor.fgHover : toneColor.fg,
      cursor: disabled ? 'not-allowed' : 'pointer',
      opacity: disabled ? 0.4 : 1,
      transition: 'background var(--dur-2) var(--ease-out), color var(--dur-2) var(--ease-out), transform var(--dur-1) var(--ease-out)',
      transform: press && !disabled ? 'scale(0.9)' : 'none',
      ...style
    }
  }, rest), /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-flex',
      width: Math.round(dim * 0.5),
      height: Math.round(dim * 0.5)
    }
  }, icon));
}
Object.assign(__ds_scope, { IconButton });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/buttons/IconButton.jsx", error: String((e && e.message) || e) }); }

// components/data/Avatar.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * Grit — Avatar
 * Circular identity token. Falls back to monogram initials on the
 * accent gradient when no image is supplied. Optional status ring.
 */
function Avatar({
  src,
  name = '',
  size = 36,
  status = null,
  // null | 'online' | 'away' | 'busy' | 'offline'
  style,
  ...rest
}) {
  const initials = name.split(' ').filter(Boolean).slice(0, 2).map(p => p[0].toUpperCase()).join('');
  const statusColors = {
    online: 'var(--grit-success)',
    away: 'var(--grit-warning)',
    busy: 'var(--grit-error)',
    offline: 'var(--text-faint)'
  };
  return /*#__PURE__*/React.createElement("span", _extends({
    style: {
      position: 'relative',
      display: 'inline-flex',
      width: size,
      height: size,
      flex: '0 0 auto',
      ...style
    }
  }, rest), /*#__PURE__*/React.createElement("span", {
    style: {
      width: size,
      height: size,
      borderRadius: '50%',
      overflow: 'hidden',
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      background: src ? 'var(--surface-input)' : 'var(--accent-grad)',
      color: 'var(--text-invert)',
      font: `var(--fw-semibold) ${Math.round(size * 0.4)}px/1 var(--font-ui)`,
      boxShadow: 'inset 0 0 0 1px rgba(255,255,255,0.08)'
    }
  }, src ? /*#__PURE__*/React.createElement("img", {
    src: src,
    alt: name,
    style: {
      width: '100%',
      height: '100%',
      objectFit: 'cover'
    }
  }) : initials), status && /*#__PURE__*/React.createElement("span", {
    style: {
      position: 'absolute',
      right: -1,
      bottom: -1,
      width: Math.max(8, size * 0.28),
      height: Math.max(8, size * 0.28),
      borderRadius: '50%',
      background: statusColors[status],
      border: '2px solid var(--surface-window)'
    }
  }));
}
Object.assign(__ds_scope, { Avatar });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/data/Avatar.jsx", error: String((e && e.message) || e) }); }

// components/data/Badge.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * Grit — Badge
 * Compact status/label pill. `tone` maps to the semantic palette;
 * `dot` prepends a status dot (great for "online / running").
 */
function Badge({
  children,
  tone = 'neutral',
  // 'neutral' | 'accent' | 'success' | 'warning' | 'error'
  variant = 'soft',
  // 'soft' | 'solid' | 'outline'
  dot = false,
  style,
  ...rest
}) {
  const tones = {
    neutral: {
      fg: 'var(--text-body)',
      soft: 'var(--surface-input)',
      solid: 'var(--surface-active)',
      dot: 'var(--text-muted)'
    },
    accent: {
      fg: 'var(--text-accent)',
      soft: 'var(--accent-fill)',
      solid: 'var(--accent)',
      dot: 'var(--accent)'
    },
    success: {
      fg: 'var(--grit-success)',
      soft: 'var(--grit-success-soft)',
      solid: 'var(--grit-success)',
      dot: 'var(--grit-success)'
    },
    warning: {
      fg: 'var(--grit-warning)',
      soft: 'var(--grit-warning-soft)',
      solid: 'var(--grit-warning)',
      dot: 'var(--grit-warning)'
    },
    error: {
      fg: 'var(--grit-error)',
      soft: 'var(--grit-error-soft)',
      solid: 'var(--grit-error)',
      dot: 'var(--grit-error)'
    }
  };
  const t = tones[tone] || tones.neutral;
  const variants = {
    soft: {
      background: t.soft,
      color: t.fg,
      border: '1px solid transparent'
    },
    solid: {
      background: t.solid,
      color: tone === 'neutral' ? 'var(--text-heading)' : 'var(--text-invert)',
      border: '1px solid transparent'
    },
    outline: {
      background: 'transparent',
      color: t.fg,
      border: `1px solid ${t.dot}`
    }
  };
  return /*#__PURE__*/React.createElement("span", _extends({
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: 6,
      height: 22,
      padding: '0 9px',
      borderRadius: 'var(--r-pill)',
      font: 'var(--fw-semibold) var(--fs-micro)/1 var(--font-ui)',
      letterSpacing: '0.03em',
      whiteSpace: 'nowrap',
      ...variants[variant],
      ...style
    }
  }, rest), dot && /*#__PURE__*/React.createElement("span", {
    style: {
      width: 6,
      height: 6,
      borderRadius: '50%',
      background: variant === 'solid' && tone !== 'neutral' ? 'currentColor' : t.dot,
      flex: '0 0 auto'
    }
  }), children);
}
Object.assign(__ds_scope, { Badge });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/data/Badge.jsx", error: String((e && e.message) || e) }); }

// components/data/Card.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * Grit — Card
 * Base surface container. `interactive` adds hover lift; `glow` adds
 * the neon edge for featured/selected cards.
 */
function Card({
  children,
  padding = 'md',
  // 'none' | 'sm' | 'md' | 'lg'
  interactive = false,
  glow = false,
  onClick,
  style,
  ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const pads = {
    none: 0,
    sm: 12,
    md: 16,
    lg: 24
  };
  return /*#__PURE__*/React.createElement("div", _extends({
    onClick: onClick,
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false),
    style: {
      background: 'var(--surface-panel)',
      border: '1px solid',
      borderColor: glow ? 'var(--focus-ring)' : 'var(--border)',
      borderRadius: 'var(--r-lg)',
      padding: pads[padding],
      boxShadow: glow ? 'var(--glow-soft), var(--shadow-md), var(--edge-light)' : interactive && hover ? 'var(--shadow-lg), var(--edge-light)' : 'var(--shadow-sm), var(--edge-light)',
      transform: interactive && hover ? 'translateY(-2px)' : 'none',
      transition: 'transform var(--dur-2) var(--ease-out), box-shadow var(--dur-2) var(--ease-out), border-color var(--dur-2) var(--ease-out)',
      cursor: interactive ? 'pointer' : 'default',
      ...style
    }
  }, rest), children);
}
Object.assign(__ds_scope, { Card });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/data/Card.jsx", error: String((e && e.message) || e) }); }

// components/data/ProgressBar.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * Grit — ProgressBar
 * Track + accent-gradient fill. `indeterminate` runs a sweeping shimmer.
 */
function ProgressBar({
  value = 0,
  // 0..100 (ignored if indeterminate)
  indeterminate = false,
  height = 6,
  tone = 'accent',
  // 'accent' | 'success' | 'warning' | 'error'
  style,
  ...rest
}) {
  const fills = {
    accent: 'var(--accent-grad)',
    success: 'var(--grit-success)',
    warning: 'var(--grit-warning)',
    error: 'var(--grit-error)'
  };
  const pct = Math.max(0, Math.min(100, value));
  const kf = 'nxProgIndet';
  return /*#__PURE__*/React.createElement("div", _extends({
    role: "progressbar",
    "aria-valuenow": indeterminate ? undefined : pct,
    style: {
      position: 'relative',
      width: '100%',
      height,
      borderRadius: 'var(--r-pill)',
      background: 'var(--surface-input)',
      boxShadow: 'inset 0 1px 2px rgba(0,0,0,0.35)',
      overflow: 'hidden',
      ...style
    }
  }, rest), /*#__PURE__*/React.createElement("style", null, `@keyframes ${kf}{0%{left:-40%}100%{left:100%}}`), /*#__PURE__*/React.createElement("div", {
    style: indeterminate ? {
      position: 'absolute',
      top: 0,
      bottom: 0,
      width: '40%',
      borderRadius: 'var(--r-pill)',
      background: fills[tone],
      animation: `${kf} 1.1s var(--ease-in-out) infinite`
    } : {
      height: '100%',
      width: `${pct}%`,
      borderRadius: 'var(--r-pill)',
      background: fills[tone],
      boxShadow: tone === 'accent' ? 'var(--glow-soft)' : 'none',
      transition: 'width var(--dur-3) var(--ease-out)'
    }
  }));
}
Object.assign(__ds_scope, { ProgressBar });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/data/ProgressBar.jsx", error: String((e && e.message) || e) }); }

// components/forms/Checkbox.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * Grit — Checkbox
 * Square check with accent fill when selected. Supports indeterminate.
 */
function Checkbox({
  checked = false,
  indeterminate = false,
  disabled = false,
  label,
  onChange,
  style,
  ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const on = checked || indeterminate;
  const box = /*#__PURE__*/React.createElement("span", {
    style: {
      position: 'relative',
      width: 18,
      height: 18,
      flex: '0 0 auto',
      borderRadius: 'var(--r-xs)',
      border: '1px solid',
      borderColor: on ? 'transparent' : hover ? 'var(--border-strong)' : 'var(--border-control)',
      background: on ? 'var(--accent-grad)' : 'var(--surface-input)',
      boxShadow: on ? 'var(--glow-soft)' : 'inset 0 1px 2px rgba(0,0,0,0.30)',
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      transition: 'background var(--dur-2) var(--ease-out), border-color var(--dur-2) var(--ease-out)'
    }
  }, indeterminate ? /*#__PURE__*/React.createElement("span", {
    style: {
      width: 9,
      height: 2,
      borderRadius: 1,
      background: '#fff'
    }
  }) : checked ? /*#__PURE__*/React.createElement("svg", {
    width: "12",
    height: "12",
    viewBox: "0 0 12 12",
    fill: "none"
  }, /*#__PURE__*/React.createElement("path", {
    d: "M2.5 6.2L4.8 8.5L9.5 3.5",
    stroke: "#fff",
    strokeWidth: "1.8",
    strokeLinecap: "round",
    strokeLinejoin: "round"
  })) : null);
  return /*#__PURE__*/React.createElement("label", {
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false),
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: 10,
      cursor: disabled ? 'not-allowed' : 'pointer',
      opacity: disabled ? 0.5 : 1,
      ...style
    }
  }, /*#__PURE__*/React.createElement("input", _extends({
    type: "checkbox",
    checked: checked,
    disabled: disabled,
    onChange: e => onChange && onChange(e.target.checked),
    style: {
      position: 'absolute',
      opacity: 0,
      width: 0,
      height: 0
    }
  }, rest)), box, label && /*#__PURE__*/React.createElement("span", {
    style: {
      font: 'var(--fw-regular) var(--fs-sm)/1 var(--font-ui)',
      color: 'var(--text-body)'
    }
  }, label));
}
Object.assign(__ds_scope, { Checkbox });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/forms/Checkbox.jsx", error: String((e && e.message) || e) }); }

// components/forms/Input.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * Grit — Input
 * Inset field on the surface ramp. Focus lights the neon ring.
 * Optional leading/trailing icon slots; supports an error state.
 */
function Input({
  value,
  defaultValue,
  placeholder,
  type = 'text',
  size = 'md',
  // 'sm' | 'md' | 'lg'
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
    sm: {
      h: 'var(--ctl-h-sm)',
      fs: 'var(--fs-xs)',
      px: 10
    },
    md: {
      h: 'var(--ctl-h-md)',
      fs: 'var(--fs-sm)',
      px: 12
    },
    lg: {
      h: 'var(--ctl-h-lg)',
      fs: 'var(--fs-base)',
      px: 14
    }
  };
  const s = sizes[size] || sizes.md;
  const iconSize = size === 'lg' ? 18 : 16;
  const borderColor = invalid ? 'var(--grit-error)' : focus ? 'var(--accent)' : hover ? 'var(--border-strong)' : 'var(--border-control)';
  return /*#__PURE__*/React.createElement("div", {
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false),
    style: {
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
      boxShadow: invalid ? '0 0 0 3px var(--grit-error-soft)' : focus ? 'var(--ring)' : 'inset 0 1px 2px rgba(0,0,0,0.30)',
      transition: 'border-color var(--dur-2) var(--ease-out), box-shadow var(--dur-2) var(--ease-out)',
      opacity: disabled ? 0.5 : 1,
      cursor: disabled ? 'not-allowed' : 'text',
      ...style
    }
  }, icon && /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-flex',
      flex: '0 0 auto',
      width: iconSize,
      height: iconSize,
      color: focus ? 'var(--text-accent)' : 'var(--text-muted)'
    }
  }, icon), /*#__PURE__*/React.createElement("input", _extends({
    value: value,
    defaultValue: defaultValue,
    placeholder: placeholder,
    type: type,
    disabled: disabled,
    onChange: onChange,
    onFocus: () => setFocus(true),
    onBlur: () => setFocus(false),
    style: {
      flex: 1,
      minWidth: 0,
      height: '100%',
      border: 'none',
      outline: 'none',
      background: 'transparent',
      color: 'var(--text-heading)',
      font: `var(--fw-regular) ${s.fs}/1 var(--font-ui)`,
      letterSpacing: '0.01em'
    }
  }, rest)), trailing && /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-flex',
      flex: '0 0 auto',
      color: 'var(--text-muted)'
    }
  }, trailing));
}
Object.assign(__ds_scope, { Input });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/forms/Input.jsx", error: String((e && e.message) || e) }); }

// components/forms/Slider.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * Grit — Slider
 * Horizontal range. Filled portion uses the accent gradient; the knob
 * lifts on hover/drag with a soft glow.
 */
function Slider({
  value = 50,
  min = 0,
  max = 100,
  step = 1,
  disabled = false,
  onChange,
  style,
  ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const pct = Math.max(0, Math.min(100, (value - min) / (max - min) * 100));
  return /*#__PURE__*/React.createElement("div", {
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false),
    style: {
      position: 'relative',
      height: 22,
      display: 'flex',
      alignItems: 'center',
      width: '100%',
      opacity: disabled ? 0.5 : 1,
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      left: 0,
      right: 0,
      height: 6,
      borderRadius: 'var(--r-pill)',
      background: 'var(--surface-input)',
      boxShadow: 'inset 0 1px 2px rgba(0,0,0,0.35)'
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      left: 0,
      width: `${pct}%`,
      height: 6,
      borderRadius: 'var(--r-pill)',
      background: 'var(--accent-grad)',
      boxShadow: hover ? 'var(--glow-soft)' : 'none',
      transition: 'box-shadow var(--dur-2) var(--ease-out)'
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      left: `calc(${pct}% - 9px)`,
      width: 18,
      height: 18,
      borderRadius: '50%',
      background: '#fff',
      border: '2px solid var(--accent)',
      boxShadow: hover ? 'var(--glow-accent)' : '0 1px 4px rgba(0,0,0,0.5)',
      transition: 'box-shadow var(--dur-2) var(--ease-out), transform var(--dur-1) var(--ease-out)',
      transform: hover ? 'scale(1.08)' : 'none'
    }
  }), /*#__PURE__*/React.createElement("input", _extends({
    type: "range",
    value: value,
    min: min,
    max: max,
    step: step,
    disabled: disabled,
    onChange: e => onChange && onChange(Number(e.target.value)),
    style: {
      position: 'absolute',
      left: 0,
      right: 0,
      width: '100%',
      height: 22,
      margin: 0,
      opacity: 0,
      cursor: disabled ? 'not-allowed' : 'pointer'
    }
  }, rest)));
}
Object.assign(__ds_scope, { Slider });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/forms/Slider.jsx", error: String((e && e.message) || e) }); }

// components/forms/Switch.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * Grit — Switch
 * Pill toggle. On state fills with the accent gradient + soft glow.
 */
function Switch({
  checked = false,
  disabled = false,
  size = 'md',
  // 'sm' | 'md'
  onChange,
  label,
  style,
  ...rest
}) {
  const dims = size === 'sm' ? {
    w: 34,
    h: 20,
    knob: 14,
    pad: 3
  } : {
    w: 42,
    h: 24,
    knob: 18,
    pad: 3
  };
  const x = checked ? dims.w - dims.knob - dims.pad : dims.pad;
  const track = /*#__PURE__*/React.createElement("button", _extends({
    type: "button",
    role: "switch",
    "aria-checked": checked,
    "aria-label": label,
    disabled: disabled,
    onClick: () => !disabled && onChange && onChange(!checked),
    style: {
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
      padding: 0
    }
  }, rest), /*#__PURE__*/React.createElement("span", {
    style: {
      position: 'absolute',
      top: dims.pad,
      left: x,
      width: dims.knob,
      height: dims.knob,
      borderRadius: '50%',
      background: checked ? '#fff' : '#C5CCD8',
      boxShadow: '0 1px 3px rgba(0,0,0,0.45)',
      transition: 'left var(--dur-3) var(--ease-spring)'
    }
  }));
  if (!label) return track;
  return /*#__PURE__*/React.createElement("label", {
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      gap: 10,
      cursor: disabled ? 'not-allowed' : 'pointer',
      ...style
    }
  }, track, /*#__PURE__*/React.createElement("span", {
    style: {
      font: 'var(--fw-medium) var(--fs-sm)/1 var(--font-ui)',
      color: 'var(--text-body)'
    }
  }, label));
}
Object.assign(__ds_scope, { Switch });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/forms/Switch.jsx", error: String((e && e.message) || e) }); }

// components/navigation/Tabs.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * Grit — Tabs
 * Segmented control with a sliding accent indicator. Controlled via
 * `value`/`onChange`. Items: { id, label, icon? }.
 */
function Tabs({
  items = [],
  value,
  onChange,
  size = 'md',
  // 'sm' | 'md'
  style,
  ...rest
}) {
  const h = size === 'sm' ? 30 : 36;
  return /*#__PURE__*/React.createElement("div", _extends({
    role: "tablist",
    style: {
      display: 'inline-flex',
      gap: 2,
      padding: 3,
      background: 'var(--surface-input)',
      border: '1px solid var(--border)',
      borderRadius: 'var(--r-md)',
      boxShadow: 'inset 0 1px 2px rgba(0,0,0,0.25)',
      ...style
    }
  }, rest), items.map(it => {
    const sel = it.id === value;
    return /*#__PURE__*/React.createElement("button", {
      key: it.id,
      role: "tab",
      "aria-selected": sel,
      onClick: () => onChange && onChange(it.id),
      style: {
        display: 'inline-flex',
        alignItems: 'center',
        gap: 7,
        height: h,
        padding: '0 14px',
        border: 'none',
        borderRadius: 'var(--r-sm)',
        background: sel ? 'var(--surface-active)' : 'transparent',
        color: sel ? 'var(--text-heading)' : 'var(--text-muted)',
        boxShadow: sel ? 'var(--shadow-xs), var(--edge-light)' : 'none',
        font: `var(--fw-medium) var(--fs-sm)/1 var(--font-ui)`,
        cursor: 'pointer',
        transition: 'background var(--dur-2) var(--ease-out), color var(--dur-2) var(--ease-out)',
        whiteSpace: 'nowrap'
      }
    }, it.icon && /*#__PURE__*/React.createElement("span", {
      style: {
        display: 'inline-flex',
        width: 15,
        height: 15,
        color: sel ? 'var(--text-accent)' : 'inherit'
      }
    }, it.icon), it.label);
  }));
}
Object.assign(__ds_scope, { Tabs });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/navigation/Tabs.jsx", error: String((e && e.message) || e) }); }

// components/os/Dock.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * Grit — Dock
 * The redesigned taskbar: a floating glass bar of app tiles. Active
 * apps get a neon underline indicator; hover lifts the tile. Pass an
 * array of items; the component is presentational (controlled).
 */
function Dock({
  items = [],
  // [{ id, icon, label, active, running }]
  onItemClick,
  style,
  ...rest
}) {
  return /*#__PURE__*/React.createElement("div", _extends({
    style: {
      display: 'inline-flex',
      alignItems: 'flex-end',
      gap: 6,
      padding: '8px 10px',
      background: 'var(--glass-tint-2)',
      backdropFilter: 'var(--blur-glass)',
      WebkitBackdropFilter: 'var(--blur-glass)',
      border: '1px solid var(--border-control)',
      borderRadius: 'var(--r-2xl)',
      boxShadow: 'var(--shadow-lg), var(--edge-light)',
      ...style
    }
  }, rest), items.map(it => /*#__PURE__*/React.createElement(DockItem, {
    key: it.id,
    item: it,
    onClick: () => onItemClick && onItemClick(it.id)
  })));
}
function DockItem({
  item,
  onClick
}) {
  const [hover, setHover] = React.useState(false);
  const [press, setPress] = React.useState(false);
  return /*#__PURE__*/React.createElement("button", {
    type: "button",
    "aria-label": item.label,
    onClick: onClick,
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => {
      setHover(false);
      setPress(false);
    },
    onMouseDown: () => setPress(true),
    onMouseUp: () => setPress(false),
    style: {
      position: 'relative',
      display: 'inline-flex',
      flexDirection: 'column',
      alignItems: 'center',
      gap: 5,
      padding: 0,
      border: 'none',
      background: 'transparent',
      cursor: 'pointer'
    }
  }, hover && /*#__PURE__*/React.createElement("span", {
    style: {
      position: 'absolute',
      bottom: 'calc(100% + 8px)',
      left: '50%',
      transform: 'translateX(-50%)',
      padding: '5px 9px',
      borderRadius: 'var(--r-sm)',
      background: 'var(--surface-active)',
      border: '1px solid var(--border-control)',
      color: 'var(--text-heading)',
      font: 'var(--fw-medium) var(--fs-xs)/1 var(--font-ui)',
      whiteSpace: 'nowrap',
      boxShadow: 'var(--shadow-pop)',
      pointerEvents: 'none'
    }
  }, item.label), /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      width: 46,
      height: 46,
      borderRadius: 'var(--r-lg)',
      background: item.active ? 'var(--accent-fill)' : 'var(--surface-panel)',
      border: '1px solid',
      borderColor: item.active ? 'var(--focus-ring)' : 'var(--border)',
      color: item.active ? 'var(--text-accent)' : 'var(--text-body)',
      boxShadow: item.active ? 'var(--glow-soft)' : hover ? 'var(--shadow-md)' : 'var(--shadow-xs)',
      transform: press ? 'scale(0.92)' : hover ? 'translateY(-6px) scale(1.06)' : 'none',
      transition: 'transform var(--dur-2) var(--ease-spring), box-shadow var(--dur-2) var(--ease-out), background var(--dur-2) var(--ease-out), border-color var(--dur-2) var(--ease-out)'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-flex',
      width: 22,
      height: 22
    }
  }, item.icon)), /*#__PURE__*/React.createElement("span", {
    style: {
      width: 5,
      height: 5,
      borderRadius: '50%',
      background: item.running ? 'var(--accent)' : 'transparent',
      boxShadow: item.running ? '0 0 6px var(--accent)' : 'none',
      transition: 'background var(--dur-2) var(--ease-out)'
    }
  }));
}
Object.assign(__ds_scope, { Dock });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/os/Dock.jsx", error: String((e && e.message) || e) }); }

// components/os/Menu.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * Grit — Menu
 * Glass popover menu for context menus, app menus and dropdowns.
 * Items: { label, icon?, shortcut?, danger?, disabled?, separator? }.
 * Presentational — position it yourself (e.g. absolute) at the anchor.
 */
function Menu({
  items = [],
  onSelect,
  width = 220,
  style,
  ...rest
}) {
  return /*#__PURE__*/React.createElement("div", _extends({
    role: "menu",
    style: {
      width,
      padding: 6,
      background: 'var(--glass-tint-2)',
      backdropFilter: 'var(--blur-glass)',
      WebkitBackdropFilter: 'var(--blur-glass)',
      border: '1px solid var(--border-control)',
      borderRadius: 'var(--r-md)',
      boxShadow: 'var(--shadow-pop), var(--edge-light)',
      ...style
    }
  }, rest), items.map((it, i) => {
    if (it.separator) {
      return /*#__PURE__*/React.createElement("div", {
        key: i,
        style: {
          height: 1,
          margin: '6px 8px',
          background: 'var(--border)'
        }
      });
    }
    return /*#__PURE__*/React.createElement(MenuItem, {
      key: i,
      item: it,
      onSelect: onSelect
    });
  }));
}
function MenuItem({
  item,
  onSelect
}) {
  const [hover, setHover] = React.useState(false);
  const danger = item.danger;
  const disabled = item.disabled;
  const fg = disabled ? 'var(--text-faint)' : danger ? 'var(--grit-error)' : 'var(--text-body)';
  return /*#__PURE__*/React.createElement("button", {
    type: "button",
    role: "menuitem",
    disabled: disabled,
    onClick: () => !disabled && onSelect && onSelect(item),
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false),
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 10,
      width: '100%',
      height: 32,
      padding: '0 10px',
      border: 'none',
      borderRadius: 'var(--r-sm)',
      background: hover && !disabled ? danger ? 'var(--grit-error-soft)' : 'var(--accent-fill)' : 'transparent',
      color: hover && !disabled && !danger ? 'var(--text-accent)' : fg,
      cursor: disabled ? 'not-allowed' : 'pointer',
      font: 'var(--fw-medium) var(--fs-sm)/1 var(--font-ui)',
      textAlign: 'left',
      transition: 'background var(--dur-1) var(--ease-out), color var(--dur-1) var(--ease-out)'
    }
  }, item.icon && /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-flex',
      width: 16,
      height: 16,
      flex: '0 0 auto'
    }
  }, item.icon), /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1
    }
  }, item.label), item.shortcut && /*#__PURE__*/React.createElement("span", {
    style: {
      font: 'var(--fw-regular) var(--fs-xs)/1 var(--font-mono)',
      color: 'var(--text-faint)',
      letterSpacing: '0.04em'
    }
  }, item.shortcut));
}
Object.assign(__ds_scope, { Menu });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/os/Menu.jsx", error: String((e && e.message) || e) }); }

// components/os/Window.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * Grit — Window
 * The redesigned application window: rounded 16px corners, a glass
 * titlebar with traffic-light controls, layered window shadow and a
 * lit top edge. Composes any content as children.
 */
function Window({
  title = 'Untitled',
  icon = null,
  children,
  toolbar = null,
  // optional node rendered as a sub-toolbar row
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
  return /*#__PURE__*/React.createElement("div", _extends({
    style: {
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
      ...style
    }
  }, rest), /*#__PURE__*/React.createElement("div", {
    style: {
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
      userSelect: 'none'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 8,
      flex: '0 0 auto'
    }
  }, /*#__PURE__*/React.createElement(Light, {
    color: "#FF6B70",
    onClick: onClose
  }), /*#__PURE__*/React.createElement(Light, {
    color: "#FFC754",
    onClick: onMinimize
  }), /*#__PURE__*/React.createElement(Light, {
    color: "var(--sage-base)",
    onClick: onMaximize
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 8,
      flex: 1,
      justifyContent: 'center',
      minWidth: 0
    }
  }, icon && /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-flex',
      width: 15,
      height: 15,
      color: 'var(--text-muted)'
    }
  }, icon), /*#__PURE__*/React.createElement("span", {
    style: {
      font: 'var(--fw-semibold) var(--fs-sm)/1 var(--font-ui)',
      color: active ? 'var(--text-heading)' : 'var(--text-muted)',
      whiteSpace: 'nowrap',
      overflow: 'hidden',
      textOverflow: 'ellipsis'
    }
  }, title)), /*#__PURE__*/React.createElement("div", {
    style: {
      width: 52,
      flex: '0 0 auto'
    }
  })), toolbar && /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 8,
      padding: '8px 12px',
      borderBottom: '1px solid var(--border)',
      background: 'var(--surface-panel)',
      flex: '0 0 auto'
    }
  }, toolbar), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      minHeight: 0,
      overflow: 'auto',
      ...bodyStyle
    }
  }, children));
}
function Light({
  color,
  onClick
}) {
  const [hover, setHover] = React.useState(false);
  return /*#__PURE__*/React.createElement("span", {
    onClick: onClick,
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false),
    style: {
      width: 12,
      height: 12,
      borderRadius: '50%',
      background: color,
      boxShadow: hover ? `0 0 0 1px rgba(255,255,255,0.25), 0 0 8px ${color}` : 'inset 0 0 0 1px rgba(0,0,0,0.15)',
      cursor: 'pointer',
      transition: 'box-shadow var(--dur-2) var(--ease-out)'
    }
  });
}
Object.assign(__ds_scope, { Window });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/os/Window.jsx", error: String((e && e.message) || e) }); }

// ui_kits/desktop/Desktop.jsx
try { (() => {
/* Grit — Desktop UI Kit · Shell
   The desktop environment: top menu bar, draggable-feeling windows
   (focus/close/minimize), and the floating dock. Window management is
   cosmetic-but-interactive: open from dock, focus by click, close. */
(function () {
  const NS = window.NexusOSDesignSystem_497743;
  const {
    Window,
    Dock,
    IconButton,
    Badge
  } = NS;
  const {
    FilesApp,
    TerminalApp,
    SettingsApp,
    MonitorApp
  } = window.GritApps;
  const I = (n, style) => React.createElement('i', {
    'data-lucide': n,
    style
  });
  const APPS = {
    files: {
      title: 'Files — Home',
      icon: 'folder',
      render: FilesApp,
      w: 560,
      h: 380,
      x: 90,
      y: 70
    },
    terminal: {
      title: 'Terminal',
      icon: 'square-terminal',
      render: TerminalApp,
      w: 520,
      h: 320,
      x: 300,
      y: 150
    },
    settings: {
      title: 'System Settings',
      icon: 'settings',
      render: SettingsApp,
      w: 540,
      h: 420,
      x: 180,
      y: 90
    },
    monitor: {
      title: 'System Monitor',
      icon: 'activity',
      render: MonitorApp,
      w: 500,
      h: 420,
      x: 360,
      y: 60
    }
  };
  function TopBar({
    clock
  }) {
    return React.createElement('div', {
      style: {
        position: 'absolute',
        top: 0,
        left: 0,
        right: 0,
        height: 34,
        zIndex: 500,
        display: 'flex',
        alignItems: 'center',
        gap: 18,
        padding: '0 14px',
        background: 'var(--glass-tint)',
        backdropFilter: 'var(--blur-thin)',
        WebkitBackdropFilter: 'var(--blur-thin)',
        borderBottom: '1px solid var(--border)',
        boxShadow: 'var(--edge-light)'
      }
    }, React.createElement('img', {
      src: '../../assets/logo-grit-mark.svg',
      style: {
        width: 16,
        height: 16
      }
    }), React.createElement('span', {
      style: {
        font: 'var(--fw-semibold) var(--fs-sm)/1 var(--font-ui)',
        color: 'var(--text-heading)'
      }
    }, 'Grit'), React.createElement('span', {
      style: {
        font: 'var(--fw-medium) var(--fs-sm)/1 var(--font-ui)',
        color: 'var(--text-muted)'
      }
    }, 'File'), React.createElement('span', {
      style: {
        font: 'var(--fw-medium) var(--fs-sm)/1 var(--font-ui)',
        color: 'var(--text-muted)'
      }
    }, 'View'), React.createElement('span', {
      style: {
        font: 'var(--fw-medium) var(--fs-sm)/1 var(--font-ui)',
        color: 'var(--text-muted)'
      }
    }, 'Window'), React.createElement('div', {
      style: {
        flex: 1
      }
    }), React.createElement('span', {
      style: {
        display: 'inline-flex',
        color: 'var(--text-body)',
        width: 15,
        height: 15
      }
    }, I('wifi')), React.createElement('span', {
      style: {
        display: 'inline-flex',
        color: 'var(--text-body)',
        width: 15,
        height: 15
      }
    }, I('volume-2')), React.createElement('span', {
      style: {
        display: 'inline-flex',
        color: 'var(--grit-success)',
        width: 15,
        height: 15
      }
    }, I('battery-full')), React.createElement('span', {
      style: {
        font: 'var(--fw-medium) var(--fs-sm)/1 var(--font-mono)',
        color: 'var(--text-heading)',
        letterSpacing: '0.02em'
      }
    }, clock));
  }
  function Desktop() {
    const [open, setOpen] = React.useState(['files', 'monitor']);
    const [focus, setFocus] = React.useState('files');
    const [pos, setPos] = React.useState(() => {
      const p = {};
      Object.keys(APPS).forEach(k => p[k] = {
        x: APPS[k].x,
        y: APPS[k].y
      });
      return p;
    });
    const [clock, setClock] = React.useState('');
    const drag = React.useRef(null);
    React.useEffect(() => {
      const tick = () => setClock(new Date().toLocaleTimeString([], {
        hour: '2-digit',
        minute: '2-digit'
      }));
      tick();
      const id = setInterval(tick, 10000);
      return () => clearInterval(id);
    }, []);
    React.useEffect(() => {
      window.lucide && window.lucide.createIcons();
    });
    const launch = id => {
      if (!APPS[id]) return;
      setOpen(o => o.includes(id) ? o : [...o, id]);
      setFocus(id);
    };
    const close = id => {
      setOpen(o => o.filter(x => x !== id));
    };

    // drag handlers (move whole window by titlebar)
    const onMouseDown = (id, e) => {
      setFocus(id);
      drag.current = {
        id,
        sx: e.clientX,
        sy: e.clientY,
        ox: pos[id].x,
        oy: pos[id].y
      };
    };
    React.useEffect(() => {
      const move = e => {
        if (!drag.current) return;
        const d = drag.current;
        setPos(p => ({
          ...p,
          [d.id]: {
            x: Math.max(0, d.ox + (e.clientX - d.sx)),
            y: Math.max(34, d.oy + (e.clientY - d.sy))
          }
        }));
      };
      const up = () => {
        drag.current = null;
      };
      window.addEventListener('mousemove', move);
      window.addEventListener('mouseup', up);
      return () => {
        window.removeEventListener('mousemove', move);
        window.removeEventListener('mouseup', up);
      };
    }, []);
    const dockItems = Object.keys(APPS).map(id => ({
      id,
      icon: I(APPS[id].icon),
      label: APPS[id].title.split(' —')[0].split(' ')[0],
      active: focus === id && open.includes(id),
      running: open.includes(id)
    }));
    return React.createElement('div', {
      className: 'grit-wall grit-wall-depth',
      style: {
        position: 'absolute',
        inset: 0,
        overflow: 'hidden'
      }
    }, React.createElement(TopBar, {
      clock
    }), open.map((id, i) => {
      const a = APPS[id];
      const isF = focus === id;
      return React.createElement('div', {
        key: id,
        onMouseDown: () => setFocus(id),
        style: {
          position: 'absolute',
          left: pos[id].x,
          top: pos[id].y,
          zIndex: isF ? 100 + i : 10 + i,
          width: a.w
        }
      }, React.createElement('div', {
        onMouseDown: e => onMouseDown(id, e),
        style: {
          cursor: 'grab'
        }
      }, React.createElement(Window, {
        title: a.title,
        icon: I(a.icon),
        width: a.w,
        height: a.h,
        active: isF,
        onClose: e => {
          e && e.stopPropagation && e.stopPropagation();
          close(id);
        },
        onMinimize: () => close(id),
        onMaximize: () => {},
        bodyStyle: {
          cursor: 'default'
        }
      }, React.createElement('div', {
        onMouseDown: e => e.stopPropagation(),
        style: {
          height: '100%'
        }
      }, React.createElement(a.render)))));
    }), React.createElement('div', {
      style: {
        position: 'absolute',
        left: '50%',
        bottom: 16,
        transform: 'translateX(-50%)',
        zIndex: 400
      }
    }, React.createElement(Dock, {
      items: dockItems,
      onItemClick: id => open.includes(id) ? setFocus(id) : launch(id)
    })));
  }
  window.GritDesktop = Desktop;
})();
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/desktop/Desktop.jsx", error: String((e && e.message) || e) }); }

// ui_kits/desktop/apps.jsx
try { (() => {
/* Grit — Desktop UI Kit · App surfaces
   Cosmetic recreations of the redesigned built-in apps. They compose
   the design-system primitives (window.<NS>) and Lucide icons. */
(function () {
  const NS = window.NexusOSDesignSystem_497743;
  const {
    Button,
    IconButton,
    Input,
    Switch,
    Slider,
    Tabs,
    Badge,
    Card,
    ProgressBar,
    Avatar
  } = NS;
  const I = (n, style) => React.createElement('i', {
    'data-lucide': n,
    style
  });

  /* ---------------- Files ---------------- */
  function FilesApp() {
    const places = [{
      ic: 'house',
      label: 'Home'
    }, {
      ic: 'folder',
      label: 'Documents'
    }, {
      ic: 'download',
      label: 'Downloads'
    }, {
      ic: 'code',
      label: 'Projects'
    }, {
      ic: 'image',
      label: 'Pictures'
    }];
    const [sel, setSel] = React.useState('grit-kernel');
    const files = [{
      n: 'grit-kernel',
      t: 'folder',
      meta: '12 items',
      d: 'Today 09:14'
    }, {
      n: 'bootloader',
      t: 'folder',
      meta: '4 items',
      d: 'Yesterday'
    }, {
      n: 'GritHL.md',
      t: 'file-text',
      meta: '18 KB',
      d: 'Jun 14'
    }, {
      n: 'desktop-shell.c',
      t: 'file-code',
      meta: '42 KB',
      d: 'Jun 12'
    }, {
      n: 'theme.dark.xml',
      t: 'file-code',
      meta: '1.2 KB',
      d: 'Jun 10'
    }, {
      n: 'boot.log',
      t: 'file',
      meta: '8 KB',
      d: 'Jun 09'
    }];
    return React.createElement('div', {
      style: {
        display: 'flex',
        height: '100%',
        minHeight: 0
      }
    },
    // sidebar
    React.createElement('div', {
      style: {
        width: 168,
        flex: '0 0 auto',
        background: 'var(--surface-app)',
        borderRight: '1px solid var(--border)',
        padding: 10,
        display: 'flex',
        flexDirection: 'column',
        gap: 2
      }
    }, React.createElement('div', {
      className: 'grit-label',
      style: {
        padding: '6px 8px 8px'
      }
    }, 'Places'), places.map(p => React.createElement('div', {
      key: p.label,
      style: {
        display: 'flex',
        alignItems: 'center',
        gap: 10,
        padding: '7px 8px',
        borderRadius: 'var(--r-sm)',
        color: 'var(--text-body)',
        cursor: 'pointer',
        font: 'var(--fw-medium) var(--fs-sm)/1 var(--font-ui)'
      }
    }, React.createElement('span', {
      style: {
        width: 16,
        height: 16,
        display: 'inline-flex',
        color: 'var(--text-muted)'
      }
    }, I(p.ic)), p.label))),
    // listing
    React.createElement('div', {
      style: {
        flex: 1,
        minWidth: 0,
        overflow: 'auto',
        padding: 8
      }
    }, React.createElement('div', {
      style: {
        display: 'grid',
        gridTemplateColumns: '1fr 90px 110px',
        padding: '4px 12px 8px',
        color: 'var(--text-faint)'
      }
    }, React.createElement('span', {
      className: 'grit-label'
    }, 'Name'), React.createElement('span', {
      className: 'grit-label'
    }, 'Size'), React.createElement('span', {
      className: 'grit-label'
    }, 'Modified')), files.map(f => React.createElement('div', {
      key: f.n,
      onClick: () => setSel(f.n),
      style: {
        display: 'grid',
        gridTemplateColumns: '1fr 90px 110px',
        alignItems: 'center',
        padding: '9px 12px',
        borderRadius: 'var(--r-sm)',
        cursor: 'pointer',
        background: sel === f.n ? 'var(--accent-fill)' : 'transparent'
      }
    }, React.createElement('span', {
      style: {
        display: 'flex',
        alignItems: 'center',
        gap: 10,
        color: sel === f.n ? 'var(--text-accent)' : 'var(--text-heading)',
        font: 'var(--fw-medium) var(--fs-sm)/1 var(--font-ui)'
      }
    }, React.createElement('span', {
      style: {
        width: 16,
        height: 16,
        display: 'inline-flex',
        color: f.t === 'folder' ? 'var(--accent)' : 'var(--text-muted)'
      }
    }, I(f.t)), f.n), React.createElement('span', {
      style: {
        font: 'var(--fw-regular) var(--fs-xs)/1 var(--font-mono)',
        color: 'var(--text-muted)'
      }
    }, f.meta), React.createElement('span', {
      style: {
        font: 'var(--fw-regular) var(--fs-xs)/1 var(--font-mono)',
        color: 'var(--text-faint)'
      }
    }, f.d)))));
  }

  /* ---------------- Terminal ---------------- */
  function TerminalApp() {
    const lines = [{
      p: '$',
      c: 'gritctl status',
      out: null
    }, {
      p: '',
      c: null,
      out: 'Grit 0.5.0  ·  kernel GritHL  ·  secure-boot OK'
    }, {
      p: '',
      c: null,
      out: 'desktop-shell  running   pid 142   gpu GOP'
    }, {
      p: '$',
      c: 'modprobe grithl --secure',
      out: null
    }, {
      p: '',
      c: null,
      out: '[  ok  ] module verified  ·  signature 0x9F2A…E1'
    }, {
      p: '$',
      c: '',
      out: null,
      cursor: true
    }];
    return React.createElement('div', {
      style: {
        height: '100%',
        background: 'var(--grit-void)',
        padding: '14px 16px',
        overflow: 'auto',
        font: 'var(--fw-regular) var(--fs-sm)/1.7 var(--font-mono)'
      }
    }, lines.map((l, i) => React.createElement('div', {
      key: i,
      style: {
        whiteSpace: 'pre-wrap'
      }
    }, l.c !== null ? React.createElement('span', null, React.createElement('span', {
      style: {
        color: 'var(--accent)'
      }
    }, l.p + ' '), React.createElement('span', {
      style: {
        color: 'var(--text-heading)'
      }
    }, l.c), l.cursor ? React.createElement('span', {
      style: {
        background: 'var(--accent)',
        color: 'transparent',
        borderRadius: 1
      }
    }, '\u00A0') : null) : React.createElement('span', {
      style: {
        color: l.out && l.out.indexOf('ok') > -1 ? 'var(--grit-success)' : 'var(--text-body)'
      }
    }, l.out))));
  }

  /* ---------------- Settings ---------------- */
  function SettingsApp() {
    const [tab, setTab] = React.useState('general');
    const [dark, setDark] = React.useState(true);
    const [wifi, setWifi] = React.useState(true);
    const [animations, setAnim] = React.useState(true);
    const [bright, setBright] = React.useState(72);
    const Row = (label, hint, control) => React.createElement('div', {
      style: {
        display: 'flex',
        alignItems: 'center',
        gap: 16,
        padding: '14px 4px',
        borderBottom: '1px solid var(--border)'
      }
    }, React.createElement('div', {
      style: {
        flex: 1
      }
    }, React.createElement('div', {
      style: {
        font: 'var(--fw-medium) var(--fs-base)/1.3 var(--font-ui)',
        color: 'var(--text-heading)'
      }
    }, label), hint ? React.createElement('div', {
      style: {
        font: 'var(--fw-regular) var(--fs-sm)/1.4 var(--font-ui)',
        color: 'var(--text-muted)',
        marginTop: 2
      }
    }, hint) : null), React.createElement('div', {
      style: {
        flex: '0 0 auto',
        minWidth: 160,
        display: 'flex',
        justifyContent: 'flex-end'
      }
    }, control));
    return React.createElement('div', {
      style: {
        padding: 18,
        overflow: 'auto',
        height: '100%'
      }
    }, React.createElement('div', {
      style: {
        marginBottom: 16
      }
    }, React.createElement(Tabs, {
      value: tab,
      onChange: setTab,
      items: [{
        id: 'general',
        label: 'General',
        icon: I('sliders-horizontal')
      }, {
        id: 'display',
        label: 'Display',
        icon: I('monitor')
      }, {
        id: 'network',
        label: 'Network',
        icon: I('wifi')
      }]
    })), Row('Dark appearance', 'Use the dark surface ramp system-wide.', React.createElement(Switch, {
      checked: dark,
      onChange: setDark
    })), Row('Interface animations', 'Window, dock and menu motion.', React.createElement(Switch, {
      checked: animations,
      onChange: setAnim
    })), Row('Wi-Fi', 'grit-secure · connected', React.createElement(Switch, {
      checked: wifi,
      onChange: setWifi
    })), Row('Brightness', null, React.createElement('div', {
      style: {
        width: 160
      }
    }, React.createElement(Slider, {
      value: bright,
      onChange: setBright
    }))), Row('Accent color', 'The system accent.', React.createElement('div', {
      style: {
        display: 'flex',
        gap: 8
      }
    }, React.createElement('span', {
      style: {
        width: 26,
        height: 26,
        borderRadius: '50%',
        background: 'var(--accent-grad)',
        boxShadow: 'var(--glow-soft)',
        border: '2px solid #fff'
      }
    }), React.createElement('span', {
      style: {
        width: 26,
        height: 26,
        borderRadius: '50%',
        background: 'var(--sage-base)'
      }
    }), React.createElement('span', {
      style: {
        width: 26,
        height: 26,
        borderRadius: '50%',
        background: 'var(--slate-base)'
      }
    }))));
  }

  /* ---------------- System Monitor ---------------- */
  function MonitorApp() {
    const stats = [{
      ic: 'cpu',
      label: 'CPU',
      val: 34,
      tone: 'accent',
      sub: '8 cores · 2.1 GHz'
    }, {
      ic: 'memory-stick',
      label: 'Memory',
      val: 61,
      tone: 'accent',
      sub: '4.9 / 8.0 GB'
    }, {
      ic: 'hard-drive',
      label: 'Disk',
      val: 48,
      tone: 'success',
      sub: '120 / 250 GB'
    }, {
      ic: 'thermometer',
      label: 'Temp',
      val: 52,
      tone: 'warning',
      sub: '52 °C · nominal'
    }];
    const procs = [{
      n: 'desktop-shell',
      cpu: '12.4',
      mem: '186 MB',
      s: 'running'
    }, {
      n: 'grit-files',
      cpu: '3.1',
      mem: '92 MB',
      s: 'running'
    }, {
      n: 'grithl-sec',
      cpu: '1.8',
      mem: '40 MB',
      s: 'running'
    }, {
      n: 'gop-compositor',
      cpu: '8.0',
      mem: '128 MB',
      s: 'running'
    }];
    return React.createElement('div', {
      style: {
        padding: 16,
        overflow: 'auto',
        height: '100%'
      }
    }, React.createElement('div', {
      style: {
        display: 'grid',
        gridTemplateColumns: '1fr 1fr',
        gap: 12,
        marginBottom: 16
      }
    }, stats.map(s => React.createElement(Card, {
      key: s.label,
      padding: 'md'
    }, React.createElement('div', {
      style: {
        display: 'flex',
        alignItems: 'center',
        gap: 9,
        marginBottom: 10
      }
    }, React.createElement('span', {
      style: {
        width: 16,
        height: 16,
        display: 'inline-flex',
        color: 'var(--text-accent)'
      }
    }, I(s.ic)), React.createElement('span', {
      className: 'grit-label'
    }, s.label), React.createElement('span', {
      style: {
        marginLeft: 'auto',
        font: 'var(--fw-semibold) var(--fs-lg)/1 var(--font-ui)',
        color: 'var(--text-heading)'
      }
    }, s.val + '%')), React.createElement(ProgressBar, {
      value: s.val,
      tone: s.tone
    }), React.createElement('div', {
      style: {
        font: 'var(--fw-regular) var(--fs-xs)/1 var(--font-mono)',
        color: 'var(--text-faint)',
        marginTop: 8
      }
    }, s.sub)))), React.createElement('div', {
      className: 'grit-label',
      style: {
        padding: '4px 2px 8px'
      }
    }, 'Processes'), procs.map(p => React.createElement('div', {
      key: p.n,
      style: {
        display: 'grid',
        gridTemplateColumns: '1fr 70px 90px 90px',
        alignItems: 'center',
        padding: '9px 4px',
        borderBottom: '1px solid var(--border)'
      }
    }, React.createElement('span', {
      style: {
        font: 'var(--fw-medium) var(--fs-sm)/1 var(--font-ui)',
        color: 'var(--text-heading)'
      }
    }, p.n), React.createElement('span', {
      style: {
        font: 'var(--fs-xs)/1 var(--font-mono)',
        color: 'var(--text-muted)'
      }
    }, p.cpu + '%'), React.createElement('span', {
      style: {
        font: 'var(--fs-xs)/1 var(--font-mono)',
        color: 'var(--text-muted)'
      }
    }, p.mem), React.createElement('span', {
      style: {
        justifySelf: 'end'
      }
    }, React.createElement(Badge, {
      tone: 'success',
      dot: true
    }, p.s)))));
  }
  window.GritApps = {
    FilesApp,
    TerminalApp,
    SettingsApp,
    MonitorApp
  };
})();
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/desktop/apps.jsx", error: String((e && e.message) || e) }); }

__ds_ns.Button = __ds_scope.Button;

__ds_ns.IconButton = __ds_scope.IconButton;

__ds_ns.Avatar = __ds_scope.Avatar;

__ds_ns.Badge = __ds_scope.Badge;

__ds_ns.Card = __ds_scope.Card;

__ds_ns.ProgressBar = __ds_scope.ProgressBar;

__ds_ns.Checkbox = __ds_scope.Checkbox;

__ds_ns.Input = __ds_scope.Input;

__ds_ns.Slider = __ds_scope.Slider;

__ds_ns.Switch = __ds_scope.Switch;

__ds_ns.Tabs = __ds_scope.Tabs;

__ds_ns.Dock = __ds_scope.Dock;

__ds_ns.Menu = __ds_scope.Menu;

__ds_ns.Window = __ds_scope.Window;

})();
