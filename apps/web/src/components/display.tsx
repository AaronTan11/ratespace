import { Check, Copy } from "lucide-react";
import { useState, type ReactNode } from "react";

import { fmt6, fullTitle, shortHex } from "@/lib/format";

/** 6 dp mono number; full precision and raw wei on hover. */
export function Num({ value, decimals = 18, unit }: { value: bigint; decimals?: number; unit?: string }) {
  return (
    <span className="rs-num" title={fullTitle(value, decimals)}>
      {fmt6(value, decimals)}
      {unit ? <span className="rs-unit">{unit}</span> : null}
    </span>
  );
}

/** 0x1234…abcd with the full value in title and a copy button. */
export function Hex({ value, head, tail }: { value: string; head?: number; tail?: number }) {
  const [copied, setCopied] = useState(false);
  async function onCopy() {
    try {
      await navigator.clipboard.writeText(value);
      setCopied(true);
      setTimeout(() => setCopied(false), 1200);
    } catch {
      // clipboard blocked: the full value is still in the title
    }
  }
  return (
    <span className="rs-hex" title={value}>
      {shortHex(value, head, tail)}
      <button
        type="button"
        className="rs-copy"
        onClick={() => void onCopy()}
        aria-label={copied ? "Copied" : `Copy ${value}`}
        data-copied={copied}
      >
        {copied ? <Check size={12} aria-hidden /> : <Copy size={12} aria-hidden />}
      </button>
    </span>
  );
}

/** Yield token (teal) against WETH (indigo). */
export function Pair({ yieldSym }: { yieldSym: string }) {
  return (
    <span className="rs-pair">
      <span className="marks" aria-hidden>
        <i style={{ background: "var(--teal)" }} />
        <i style={{ background: "var(--weth)" }} />
      </span>
      <span>
        {yieldSym}
        <span className="sep"> / </span>WETH
      </span>
    </span>
  );
}

export function Skel({ w = 96 }: { w?: number }) {
  return <span className="rs-skel" style={{ width: w }} aria-label="Loading" />;
}

export function Panel({
  title,
  meta,
  children,
  bodyClass = "rs-panel-body",
}: {
  title: ReactNode;
  meta?: ReactNode;
  children: ReactNode;
  bodyClass?: string;
}) {
  return (
    <section className="rs-panel">
      <div className="rs-panel-head">
        <span className="rs-eyebrow">{title}</span>
        {meta ? <span className="rs-meta">{meta}</span> : null}
      </div>
      <div className={bodyClass}>{children}</div>
    </section>
  );
}

export function PageHead({ eyebrow, title, right }: { eyebrow: string; title: ReactNode; right?: ReactNode }) {
  return (
    <div className="rs-head">
      <div>
        <div className="rs-eyebrow">{eyebrow}</div>
        <h1>{title}</h1>
      </div>
      {right}
    </div>
  );
}
