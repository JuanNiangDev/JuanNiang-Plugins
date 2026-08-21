# 插件头像风格指南

本仓库所有插件的 `avatar.png` 统一采用「卷娘」品牌视觉语言绘制，保证商店与群内展示的一致性。本文档给出可复用的**风格绘制提示词**与**校验提示词**，新增或重绘插件头像时直接套用即可。

## 一、品牌视觉规范

所有图标须同时满足以下约束：

- **配色**：纯白（`#FFFFFF`）为主表面，浅粉（`#FFD6E8` 一类柔粉）作点缀（如内部装饰、高光、附件），深蓝偏紫（`#2A3B8F` 一类）作均匀描边轮廓。
- **风格**：卡通二次元萌系、极度简化、圆润无锐角、大头小比例、`baby-cute` 气质。
- **光影**：纯平涂，无阴影、无渐变、无高光、无柔光晕（hard edge）。
- **构图**：**单一主体**，居中，占满大部分画面；不加入吉祥物本体，只画与插件功能相关的元素。
- **背景**：透明（`alpha` 通道透明）。
- **禁项**：不出现文字 / 字母 / 数字、不出现兔子或任何动物吉祥物、不出现真实 Logo 商标。

> 灵感来源原则：极简、4–7 个大圆角形状构成单一可辨识剪影、三色语义（白 + 粉 + 深蓝）、构图从下角或居中突出主体。

## 二、风格绘制提示词（通用模板）

将下方模板中的 `__SUBJECT__` 替换为「该插件图标的主体描述（英文，单主体）」后提交给图像生成即可。

```text
A single cute rounded __SUBJECT__, drawn in a flat cartoon anime mascot style: pure white surfaces, soft light-pink accents, outlined with a clean deep blue bluish-purple contour line of uniform thickness, smooth rounded shapes, no shadows, no gradients, no shading, minimal baby-cute appeal, big simple shapes, solid opaque flat fill, clean hard edges, no glow, no soft shadow, no halo. Large and centered, filling most of the square frame, transparent background, single subject only, no text, no letters, no logo, no animal, no mascot, no rabbit, no character, object only.
```

**主体描述写法要点**

- 只写一个名词性主体，例如 `code repository folder showing a few code lines with a small link mark`。
- 用 `rounded` / `cute` 保持萌系；用 `large ... filling most of the square frame` 保证主体占比。
- 不要在此处写「logo / icon / avatar / app icon」等用途词，只描述这张方形插画本身。
- 提示词本身即「画一张图」，不要让模型知道这是用作图标。

### 各插件主体清单（可直接复用）

| 插件 | `__SUBJECT__` 主体描述 |
|---|---|
| checkin | desk calendar card with a bold checkmark on its page |
| cron-example | round wall clock with two simple hands |
| ping | rounded location pin with three concentric signal rings around it |
| poke-reply | cartoon hand with one extended index finger poking forward |
| redrock_caidanci | rounded wooden alphabet block cube showing a letter |
| redrock_caidanci_grade | rounded alphabet block cube topped with a small graduation cap |
| redrock_code | rounded computer terminal window showing a code bracket symbol |
| redrock_cron_msg | rounded paper envelope with a small clock on its corner |
| redrock_fanzha | rounded shield with a bold exclamation mark |
| redrock_faq | rounded speech bubble with a bold question mark |
| redrock_group_manager | rounded cluster of three simple people figures |
| redrock_poke | cartoon hand with one extended finger touching a small rounded star burst |
| redrock_quiz | rounded light bulb with a question mark |
| redrock_special | rounded easter egg with a small star on it |
| redrock_welcome | cartoon open hand waving hello |
| rich-demo | rounded picture frame with a small mountain and sun inside it |
| system | single rounded gear cog |
| t2i-example | rounded picture frame with a small magic wand and sparkles |
| webhook-example | rounded chain link connector made of two interlocking links |
| welcome | rounded open door with a small sparkle |
| repo-intro | code repository folder showing a few code lines with a small link mark |
| wechat-article-summary | article document card with several text lines and a small sparkle |

> 新插件按「功能 → 一个具象元素」推导主体即可，例如定时类用时钟/信封+时钟，查询类用气泡/灯泡/盾牌等。

## 三、校验提示词（通用模板）

生成后，用下方提示词对成品做视觉校验（把 `__EXPECTED__` 换成该插件的预期主体关键词）。

```text
只输出：主体是什么？背景是否透明？是否出现兔子/动物吉祥物？配色是否白色+浅粉+深蓝描边扁平风？用中文简短回答。预期主体应类似：__EXPECTED__。
```

**校验要点（四项全过才算合格）**

1. **主体一致**：视觉识别出的主体与预期相符，且为单一主体，无多余无关元素。
2. **透明背景**：背景须为透明。注意——肉眼/合成预览常把透明 PNG 显示成白底或黑底，会误报"背景不透明"；须以图像的 `alpha` 通道核实（存在大量 `alpha=0` 像素且主体区域 `alpha` 接近不透明方为合格）。
3. **无吉祥物**：不得出现兔子或任何动物形象。
4. **配色合规**：主体为白 + 浅粉 + 深蓝描边的扁平风，无渐变/阴影/柔光。

任一项不通过即重绘，重绘时可在主体描述后追加 `large and centered, filling most of the square frame` 以纠正主体偏小，或追加更明确的负向约束排除误带吉祥物。
