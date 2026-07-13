import * as React from 'react';

export interface MenuItemModel {
  label?: string;
  icon?: React.ReactNode;
  /** Right-aligned shortcut hint, e.g. "⌘C". */
  shortcut?: string;
  danger?: boolean;
  disabled?: boolean;
  /** Render a divider instead of an item. */
  separator?: boolean;
  /** Free-form payload returned by onSelect. */
  value?: unknown;
}

export interface MenuProps {
  items?: MenuItemModel[];
  onSelect?: (item: MenuItemModel) => void;
  width?: number;
  style?: React.CSSProperties;
}

/** Glass popover menu for context menus, app menus and dropdowns. */
export function Menu(props: MenuProps): JSX.Element;
