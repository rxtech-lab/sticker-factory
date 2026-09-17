import { describe, expect, it } from 'vitest';
import sharp from 'sharp';
import { creationPresetCatalog } from '@/lib/creation-presets/catalog';
import { resolveCreationPresets } from '@/lib/creation-presets/selection';
import { creationPresetReferences, withPresetArtworkReferences } from '@/lib/creation-presets/references';
import { userTurn, viewableReferences } from '@/lib/ai/gateway-models';
import { compactingPrepareStep } from '@/lib/ai/compaction';
const submission={catalogVersion:creationPresetCatalog.version,selections:[{groupId:'style',optionIds:['clay']},{groupId:'theme',optionIds:['space','cozy']}]};
describe('preset visual references',()=>{
 it('loads all selected covers from the saved snapshot after catalog edits',async()=>{
  const catalog=structuredClone(creationPresetCatalog);
  const snapshot=resolveCreationPresets(submission,catalog);
  catalog.groups[0].options=[];
  const visuals=await creationPresetReferences(snapshot);
  expect(visuals.map(v=>v.label)).toEqual(['Style: 3D Clay','Theme: Cozy Days','Theme: Space']);
  for(const visual of visuals) expect((await sharp(visual.image.bytes).metadata()).width).toBe(512);
  const messages=userTurn('My dog, preserve his identity',[],visuals);
  expect(JSON.stringify(messages,(key,value)=>key==='image'?'[image]':value)).toContain('Do not copy');
  const prepared=compactingPrepareStep({loop:'test',compactAfterTokens:1});
  // The preset pictures are initial context, so tool-history compaction retains them.
  const result=await prepared({messages,stepNumber:20} as Parameters<typeof prepared>[0]);
  expect((result?.messages?.[0].content as unknown[]).length).toBe(7);
 });
 it('passes all eight user photos alongside the covers without changing the source/mask slot',async()=>{
  const visuals=await creationPresetReferences(resolveCreationPresets(submission));
  const references=Array.from({length:8},()=>visuals[0].image);
  const prepared=await withPresetArtworkReferences(references,visuals);
  expect(prepared.references).toHaveLength(8);
  expect(prepared.references.slice(0,7)).toEqual(references.slice(0,7));
  expect(prepared.note).toContain('original eighth reference');
  const combined=await sharp(prepared.references[7].bytes).metadata();
  expect(combined.height).toBeGreaterThan(1024);
  expect(await viewableReferences(references)).toHaveLength(8);
 });
 it('adds covers even when no subject photo is attached and rejects unsafe stored paths',async()=>{
  const snapshot=resolveCreationPresets(submission)!;
  const prepared=await withPresetArtworkReferences([],await creationPresetReferences(snapshot));
  expect(prepared.references).toHaveLength(1);
  expect(prepared.note).toContain('never copy their mascot');
  snapshot.selections[0].options[0].cover='/../../etc/passwd';
  await expect(creationPresetReferences(snapshot)).rejects.toThrow('Unsupported');
 });
});
