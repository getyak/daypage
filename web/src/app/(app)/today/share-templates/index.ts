import type { FC } from "react";
import { MinimalTemplate } from "./MinimalTemplate";
import { FilmTemplate } from "./FilmTemplate";
import { PolaroidTemplate } from "./PolaroidTemplate";
import { JournalTemplate } from "./JournalTemplate";
import { PostcardTemplate } from "./PostcardTemplate";

export type ShareTemplateProps = {
  body: string;
  created_at: string;
  place_name?: string;
  type: string;
  photo_url?: string;
  weather?: string;
};

export type TemplateId = "minimal" | "film" | "polaroid" | "journal" | "postcard";

export type TemplateEntry = {
  id: TemplateId;
  label: string;
  component: FC<ShareTemplateProps>;
};

// Chinese serif labels per design (detail.jsx:762 SHARE_TEMPLATE_LABELS)
export const SHARE_TEMPLATES: TemplateEntry[] = [
  { id: "minimal", label: "极简", component: MinimalTemplate },
  { id: "film", label: "胶片", component: FilmTemplate },
  { id: "polaroid", label: "拍立得", component: PolaroidTemplate },
  { id: "journal", label: "手账", component: JournalTemplate },
  { id: "postcard", label: "明信片", component: PostcardTemplate },
];
