import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { ImageResponse } from "next/og";
import { routing } from "@/i18n/routing";

export const alt = "Hawky";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

/* ビルド時に焼く。動的なままだと public/ が関数側に含まれず、
   本番で icon.png を読めずに 500 になる */
export function generateStaticParams(): { locale: string }[] {
  return routing.locales.map((locale) => ({ locale }));
}

/* 出るのは kk-web の一覧で176px、X のカードで500px 前後。
   その大きさで残るのはアイコンと名前と1行だけ。色はアイコンから取る */
const EMBER = "#1d0e0a";
const AMBER = "#ffb23e";
const WHITE = "#fff7ee";

export default async function OgImage({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<ImageResponse> {
  const { locale } = await params;
  const isJa = locale === "ja";
  /* 見出しの書体はサイトと同じ Dela Gothic One。使う文字だけに絞ったものを
     同梱している。文言を変えたら assets/README.md の手順で作り直す */
  const [icon, font] = await Promise.all([
    readFile(join(process.cwd(), "public/icon.png")),
    readFile(join(process.cwd(), "assets/DelaGothicOne-subset.ttf")),
  ]);
  const iconSrc = `data:image/png;base64,${icon.toString("base64")}`;

  return new ImageResponse(
    <div
      style={{
        alignItems: "center",
        /* 地をアイコンと同じ色にすると、アイコンの輪郭が溶けて消える。
           濃い地に、アイコンの琥珀と朱を光として置く */
        background: EMBER,
        backgroundImage:
          "radial-gradient(55% 70% at 12% 20%, rgba(255,178,62,0.42) 0%, rgba(29,14,10,0) 62%), radial-gradient(60% 70% at 95% 95%, rgba(242,86,45,0.45) 0%, rgba(29,14,10,0) 60%)",
        display: "flex",
        gap: 56,
        height: "100%",
        justifyContent: "center",
        width: "100%",
      }}
    >
      {/* biome-ignore lint/performance/noImgElement: next/image is not available in ImageResponse */}
      <img alt="" height={250} src={iconSrc} width={250} />
      <div style={{ display: "flex", flexDirection: "column" }}>
        <div style={{ color: WHITE, fontSize: 118 }}>Hawky</div>
        <div style={{ color: AMBER, display: "flex", fontSize: 34, marginTop: 14 }}>
          {isJa ? "Claude Code の許可待ちに気付く。" : "Claude Code is waiting. Hawky noticed."}
        </div>
      </div>
    </div>,
    {
      ...size,
      fonts: [{ data: font, name: "Dela Gothic One", style: "normal", weight: 400 }],
    },
  );
}
