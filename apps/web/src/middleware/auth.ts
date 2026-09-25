import { createMiddleware } from "@tanstack/react-start";

import { auth } from "../services";

export const authMiddleware = createMiddleware().server(async ({ next, request }) => {
  const session = await auth.api.getSession({
    headers: request.headers,
  });
  return next({
    context: { session },
  });
});
