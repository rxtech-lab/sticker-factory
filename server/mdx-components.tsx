import type { MDXComponents } from "mdx/types";
import { TutorialStep, TutorialMedia, TutorialCallout, TutorialActionLink } from "@/components/tutorial/tutorial-reader";
const components = { TutorialStep, TutorialMedia, TutorialCallout, TutorialActionLink } satisfies MDXComponents;
export function useMDXComponents(): MDXComponents { return components; }
