import * as React from 'react';

export interface AvatarProps {
  src?: string;
  /** Used for the monogram fallback and alt text. */
  name?: string;
  /** Pixel diameter. @default 36 */
  size?: number;
  status?: 'online' | 'away' | 'busy' | 'offline' | null;
  style?: React.CSSProperties;
}

/** Circular identity token; monogram fallback on the accent gradient. */
export function Avatar(props: AvatarProps): JSX.Element;
