import { Toaster } from "@ratespace/ui/components/sonner";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { HeadContent, Outlet, Scripts, createRootRouteWithContext } from "@tanstack/react-router";
import { TanStackRouterDevtools } from "@tanstack/react-router-devtools";
import { useState } from "react";

import Header from "../components/header";
import { WalletProvider } from "../lib/chain/wallet";

import appCss from "../index.css?url";

export interface RouterAppContext {}

// Router devtools badge: dev only. Hidden in production builds and when VITE_HIDE_DEVTOOLS=1
// (the e2e run and clean demo recordings: `VITE_HIDE_DEVTOOLS=1 bun run dev:web`).
const SHOW_DEVTOOLS = !import.meta.env.PROD && import.meta.env.VITE_HIDE_DEVTOOLS !== "1";

export const Route = createRootRouteWithContext<RouterAppContext>()({
  head: () => ({
    meta: [
      {
        charSet: "utf-8",
      },
      {
        name: "viewport",
        content: "width=device-width, initial-scale=1",
      },
      {
        title: "RateSpace",
      },
    ],
    links: [
      { rel: "preconnect", href: "https://fonts.googleapis.com" },
      { rel: "preconnect", href: "https://fonts.gstatic.com", crossOrigin: "anonymous" },
      {
        rel: "stylesheet",
        href: "https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600&family=Geist+Mono:wght@400;500&display=swap",
      },
      {
        rel: "stylesheet",
        href: appCss,
      },
    ],
  }),

  component: RootDocument,
});

function RootDocument() {
  const [queryClient] = useState(() => new QueryClient());
  return (
    <html lang="en" className="dark">
      <head>
        <HeadContent />
      </head>
      <body>
        <QueryClientProvider client={queryClient}>
          <WalletProvider>
            <div className="grid min-h-svh grid-rows-[auto_1fr] content-start">
              <Header />
              <Outlet />
            </div>
          </WalletProvider>
        </QueryClientProvider>
        <Toaster theme="dark" />
        {SHOW_DEVTOOLS ? <TanStackRouterDevtools position="bottom-left" /> : null}
        <Scripts />
      </body>
    </html>
  );
}
