/** Team prefix must match the distribution signing identity of the full app and clip. */
export async function GET() {
  const team = process.env.APPLE_APP_TEAM_ID ?? "T7GYB573Y6";
  return Response.json({
    appclips: { apps: [`${team}.app.rxlab.stickerfactory.Clip`] },
    applinks: { details: [{ appIDs: [`${team}.app.rxlab.stickerfactory`], components: [
      { "/": "/share/ios" }, { "/": "/share/ios/packs/*" },
    ] }] },
  }, { headers: { "Cache-Control": "public, max-age=3600" } });
}
