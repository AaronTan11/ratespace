import { createAuth } from "@ratespace/auth";
import { createDb } from "@ratespace/db";

import { ENV } from "./env.server";

export const db = createDb(ENV);
export const auth = createAuth(ENV, db);
