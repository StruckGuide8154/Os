import * as React from 'react';

export interface WindowProps {
  title?: string;
  /** Small icon node shown beside the title. */
  icon?: React.ReactNode;
  children?: React.ReactNode;
  /** Optional sub-toolbar row rendered under the titlebar. */
  toolbar?: React.ReactNode;
  width?: number | string;
  height?: number | string;
  /** Focused vs background window styling. @default true */
  active?: boolean;
  onClose?: () => void;
  onMinimize?: () => void;
  onMaximize?: () => void;
  style?: React.CSSProperties;
  bodyStyle?: React.CSSProperties;
}

/**
 * The redesigned Grit application window — glass titlebar, traffic
 * lights, 16px corners, layered shadow.
 * @startingPoint section="Shell" subtitle="Application window chrome with glass titlebar" viewport="700x460"
 */
export function Window(props: WindowProps): JSX.Element;
