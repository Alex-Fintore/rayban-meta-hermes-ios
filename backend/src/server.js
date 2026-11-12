import { createApp } from "./app.js";

const port = Number(process.env.PORT ?? 8787);

try {
  const app = createApp();
  app.listen(port, () => {
    console.log(`Ray-Ban Hermes gateway listening on ${port}`);
  });
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
