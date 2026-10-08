import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import sharp from "sharp";
import { SVGAnimationRigSchema, SVGSceneSchema, safeVectorMarkup, type SVGState } from "@/lib/contracts/controllable";
import { sampleSVG, renderSVG } from "@/lib/controllable/sample";
import { StickerDocumentSchema, downcastForClient, resolveStickerConfiguration } from "@/lib/contracts/sticker";
const fixture = JSON.parse(readFileSync(new URL("../../../StickerGeniOS/packages/AnimatedView/Tests/AnimatedViewTests/Fixtures/controllable-svg-parity.json", import.meta.url), "utf8"));
const rig = SVGAnimationRigSchema.parse(fixture.rig);

describe("controllable SVG", () => {
  it("matches shared native timing, light, rain and shelter states", () => {
    for (const c of fixture.cases) {
      const groups = sampleSVG(rig, c.state as SVGState, c.time);
      expect(groups[0].x).toBe(c.x);
      expect(groups[0]).toMatchObject(c.channels);
      for (const id of ["lamp", "umbrella", "face"]) expect(groups.find(g => g.id === id)?.visible).toBe(c[id]);
    }
  });
  it("renders changing vector frames without external assets", async () => {
    const render = (time: number) => sharp(Buffer.from(renderSVG(rig, {}, time))).png().toBuffer();
    expect(await render(0)).not.toEqual(await render(1));
    expect(await render(0)).toEqual(await render(2));
  });
  it.each([
    '<svg><script>alert(1)</script></svg>', '<svg onload="alert(1)"/>',
    '<svg><image href="https://example.com/a.png"/></svg>', '<svg><style>@import "x"</style></svg>',
    '<!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]><svg>&x;</svg>',
    '<svg><g></svg>', '<svg fill="url(#missing)"/>', '<svg><g id="cycle" clip-path="url(#cycle)"/></svg>', '<svg/><svg/>', '<svg fill="url(https://example.com)"/>', '<svg><foreignObject/></svg>',
  ])("rejects unsupported or executable markup: %s", markup => expect(safeVectorMarkup(markup)).toBe(false));
  it("rejects duplicate ids and unordered keyframes", () => {
    expect(SVGAnimationRigSchema.safeParse({ ...rig, groups: [rig.groups[0], rig.groups[0]] }).success).toBe(false);
    const copy = structuredClone(rig); copy.groups[0].tracks[0].frames.reverse();
    expect(SVGAnimationRigSchema.safeParse(copy).success).toBe(false);
  });
  it("rejects a spawn inside an obstacle", () => {
    const polygon = [{x:0,y:0},{x:1,y:0},{x:1,y:1},{x:0,y:1}];
    expect(SVGSceneSchema.safeParse({ version:1, engine:"svg", rig, indoor:false, spawn:{x:.5,y:.5}, walkable:polygon, obstacles:[polygon], shelters:[], fixtures:{clock:null,weather:null,status:null} }).success).toBe(false);
  });
  it("rejects thin obstacles inside the spawn footprint", () => {
    const scene = JSON.parse(readFileSync(new URL("../../../StickerGeniOS/packages/AnimatedView/Tests/AnimatedViewTests/Fixtures/controllable-scene.json", import.meta.url), "utf8"));
    expect(SVGSceneSchema.safeParse(scene).success).toBe(true);
    scene.spawn = { x: .2, y: .7 };
    scene.obstacles = [[{x:.209,y:0},{x:.21,y:0},{x:.21,y:1},{x:.209,y:1}]];
    expect(SVGSceneSchema.safeParse(scene).success).toBe(false);
  });
  it("resolves SVG expressions and gives old clients a poster without controls", () => {
    const document = StickerDocumentSchema.parse({ version:8, engine:"svg", kind:"animated", durationSeconds:2, fps:24, loop:"loop", canvas:{width:200,height:200,coordinateSpace:"normalized",transparent:true},
      layers:[{id:"pet",name:"Pet",type:"svg",source:{kind:"inline",markup:rig.groups[0].markup},rig,posterAssetId:"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}],
      configuration:{ controls:[{id:"mood",label:"Mood",type:"choice",defaultValue:"calm",options:[{id:"calm",label:"Calm"},{id:"happy",label:"Happy"}]}],variants:[{id:"calm",selections:{mood:"calm"},layers:[{layerId:"pet",expression:"calm"}]},{id:"happy",selections:{mood:"happy"},layers:[{layerId:"pet",expression:"happy"}]}]}});
    expect(resolveStickerConfiguration(document,{mood:"happy"}).layers[0]).toMatchObject({svgState:{expression:"happy"}});
    expect(downcastForClient(document,7)).toMatchObject({version:7,layers:[{type:"image",assetId:"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}]});
    expect(downcastForClient(document,7)).not.toHaveProperty("configuration");
    expect(StickerDocumentSchema.parse({...document, version:7}).version).toBe(8);
  });
});
