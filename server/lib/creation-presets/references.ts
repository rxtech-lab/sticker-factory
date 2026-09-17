import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import sharp, { type OverlayOptions } from 'sharp';
import type { AiPlanVisual, AiReferenceImage } from '@/lib/ai/gateway-contracts';
import type { CreationPresetSnapshot } from '@/lib/contracts/creation-presets';

const cache = new Map<string, Promise<AiReferenceImage>>();
/** These are immutable, server-owned cover paths from the saved snapshot, never submitted URLs. */
export async function creationPresetReferences(snapshot: CreationPresetSnapshot | null | undefined): Promise<AiPlanVisual[]> {
  return Promise.all((snapshot?.selections ?? []).flatMap(group => group.options.map(async option => {
    if (!/^\/images\/creation\/v[\w.-]+\/[a-z0-9-]+(?:\/cover)?\.webp$/.test(option.cover)) throw new Error('Unsupported saved preset cover path');
    let image = cache.get(option.cover);
    if (!image) {
      image = readFile(resolve(process.cwd(), `public${option.cover}`)).then(async bytes => ({
        // First frame is enough to communicate visual style, including for an animated WebP cover.
        bytes: new Uint8Array(await sharp(bytes).resize(512,512,{fit:'inside',withoutEnlargement:true}).png().toBuffer()), mimeType: 'image/png',
      }));
      cache.set(option.cover,image);
      image.catch(() => cache.delete(option.cover));
      if (cache.size > 128) cache.delete(cache.keys().next().value!);
    }
    return {label: `${group.title.en}: ${option.title.en}`,image: await image};
  })));
}

const escape = (text: string) => text.replace(/[<>&"']/g, character => ({'<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;',"'":'&apos;'}[character]!));
/** One labelled board keeps every selected cover visible without taking slots away from photos. */
export async function presetReferenceBoard(visuals: AiPlanVisual[]): Promise<AiReferenceImage> {
  const tile=256, labelHeight=44, columns=Math.min(4,Math.ceil(Math.sqrt(visuals.length)));
  const width=columns*tile, height=Math.ceil(visuals.length/columns)*(tile+labelHeight);
  const composite: OverlayOptions[]=[];
  for (const [index,visual] of visuals.entries()) {
    const left=index%columns*tile, top=Math.floor(index/columns)*(tile+labelHeight);
    composite.push({input:await sharp(visual.image.bytes).resize(tile,tile,{fit:'contain',background:'#fff8e9'}).png().toBuffer(),left,top});
    const label=`<svg width="${tile}" height="${labelHeight}"><text x="128" y="26" text-anchor="middle" font-family="sans-serif" font-size="13" fill="#332718">${escape(visual.label)}</text></svg>`;
    composite.push({input:Buffer.from(label),left,top:top+tile});
  }
  return {bytes:new Uint8Array(await sharp({create:{width,height,channels:4,background:'#fff8e9'}}).composite(composite).png().toBuffer()),mimeType:'image/png'};
}

/** Preserve the eight-image provider limit and all user/approved references. The rare full input
 * combines its last photo with the example board; the first/source image and mask stay untouched. */
export async function withPresetArtworkReferences(references: AiReferenceImage[], visuals: AiPlanVisual[]): Promise<{references: AiReferenceImage[]; note: string}> {
  if (references.length > 8) throw new Error('At most eight subject references are supported');
  if (!visuals.length) return {references,note:''};
  const board=await presetReferenceBoard(visuals);
  const instruction='The labelled preset examples are visual guidance only: use their style/theme, never copy their mascot, subject, lettering, panel layout, or background. Preserve the requested subject, user photo identity, and approved artwork. ';
  if (references.length < 8) return {references:[...references,board],note:instruction+`Reference ${references.length+1} is the preset example board.`};
  const last=await sharp(references[7].bytes).resize(1024,1024,{fit:'contain',background:'#ffffff'}).png().toBuffer();
  const lower=await sharp(board.bytes).resize({width:1024}).png().toBuffer();
  const height=(await sharp(lower).metadata()).height!;
  const combined=await sharp({create:{width:1024,height:1024+height,channels:4,background:'#ffffff'}})
    .composite([{input:last,top:0,left:0},{input:lower,top:1024,left:0}]).png().toBuffer();
  return {references:[...references.slice(0,7),{bytes:new Uint8Array(combined),mimeType:'image/png'}],note:instruction+'Reference 8 contains the original eighth reference in its upper panel, followed by the labelled preset example board below. The other seven references are unchanged.'};
}
