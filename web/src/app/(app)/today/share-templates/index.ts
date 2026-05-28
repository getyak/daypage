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

export const SHARE_TEMPLATES: TemplateEntry[] = [
  { id: "minimal", label: "MINIMAL", component: MinimalTemplate },
  { id: "film", label: "FILM", component: FilmTemplate },
  { id: "polaroid", label: "POLAROID", component: PolaroidTemplate },
  { id: "journal", label: "JOURNAL", component: JournalTemplate },
  { id: "postcard", label: "POSTCARD", component: PostcardTemplate },
];
