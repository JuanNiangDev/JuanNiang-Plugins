# 插件头像风格指南

本仓库所有插件的 `avatar.png` 统一采用「卷娘」品牌视觉语言绘制，保证商店与群内展示的一致性。本文档给出可复用的**风格绘制提示词**与**校验提示词**，新增或重绘插件头像时直接套用即可。

## 一、品牌视觉规范

所有图标须同时满足以下约束：

- **配色**：纯白（`#FFFFFF`）为主表面，浅粉（`#FFD6E8` 一类柔粉）作点缀（内部装饰、附件，**以及柔和高光**），深蓝偏紫（`#2A3B8F` 一类）作均匀描边轮廓。
- **风格**：卡通二次元萌系、极度简化、圆润无锐角、大头小比例、`baby-cute` 气质。
- **光影**：保留柔和高光（浅粉或白色高光点缀，体现圆润光泽）；不做投影（cast shadow）、不做大幅渐变、不做体积光 / 3D 效果，整体仍属扁平卡通风。
- **人物与动物**：禁止兔子或任何动物吉祥物；抽象人物、群像（如群管理）允许作为主体。
- **构图**：**单一主体**，居中，占满大部分画面；不加入吉祥物本体，只画与插件功能相关的元素。
- **背景**：透明（`alpha` 通道透明）。
- **禁项**：默认不出现文字 / 字母 / 数字 / 真实 Logo 商标；**例外**：当插件功能与字母或单词直接相关（如猜单词游戏）时，字母可作为主体元素（如字母方块）。不出现兔子或任何动物吉祥物（抽象人物 / 群像允许）。

> 灵感来源原则：极简、4–7 个大圆角形状构成单一可辨识剪影、三色语义（白 + 粉 + 深蓝）、构图从下角或居中突出主体。

## 二、风格绘制提示词（通用模板）

将下方模板中的 `__SUBJECT__` 替换为「该插件图标的主体描述（英文，单主体）」后提交给图像生成即可。

```text
A single cute rounded __SUBJECT__, drawn in a flat cartoon anime mascot style: pure white surfaces, soft light-pink accents, outlined with a clean deep blue bluish-purple contour line of uniform thickness, smooth rounded shapes, no cast shadows, no heavy gradients, subtle soft highlights allowed, minimal baby-cute appeal, big simple shapes, solid opaque flat fill, clean edges, no glow, no halo. Large and centered, filling most of the square frame, transparent background, single subject only, no text, no letters, no logo unless the subject itself is letter-based, no animal, no mascot, no rabbit, no character, object only.
```

**主体描述写法要点**

- 只写一个名词性主体，例如 `code repository folder showing a few code lines with a small link mark`。
- 用 `rounded` / `cute` 保持萌系；用 `large ... filling most of the square frame` 保证主体占比。
- 不要在此处写「logo / icon / avatar / app icon」等用途词，只描述这张方形插画本身。
- 提示词本身即「画一张图」，不要让模型知道这是用作图标。
- 字母类插件（如猜单词）在 `__SUBJECT__` 中直接写明 `showing a single capital letter A`，此即「字母作为主体」的例外，覆盖通用模板里的 `no letters`。

### 各插件主体清单（可直接复用）

| 插件 | `__SUBJECT__` 主体描述 |
|---|---|
| checkin | desk calendar card with a bold checkmark on its page |
| cron-example | round wall clock with two simple hands |
| ping | rounded location pin with three concentric signal rings around it |
| poke-reply | cartoon hand with one extended index finger poking forward |
| redrock_caidanci | rounded wooden alphabet block cube showing a single capital letter A _(字母作为主体，属禁项例外)_ |
| redrock_caidanci_grade | rounded alphabet block cube showing a single capital letter A, topped with a small graduation cap _(字母作为主体，属禁项例外)_ |
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

> 新插件按「功能 → 一个具象元素」推导主体即可，例如定时类用时钟/信封+时钟，查询类用气泡/灯泡/盾牌等。字母类（猜单词等）允许以字母方块作为主体。

## 三、校验提示词（通用模板）

生成后，用下方提示词对成品做视觉校验（把 `__EXPECTED__` 换成该插件的预期主体关键词）。

```text
只输出：主体是什么？背景是否透明？是否出现兔子/动物吉祥物？配色是否白色+浅粉+深蓝描边扁平风（允许柔和高光）？用中文简短回答。主体必须与「__EXPECTED__」完全一致；若出现其他主体或无关元素，判为不通过。
```

**校验要点（四项全过才算合格）**
   - 明显半透明像素 `0<alpha<250` 占比 **≤ 30%**（抗锯齿 / 高光边缘容差，含 250–255 近不透明柔边；超出则为大面积柔光 / 半透明，不合格）。
1. **主体明确匹配**：视觉识别出的主体必须与预期 `__EXPECTED__` **完全一致**；允许同义表述，但不允许出现其他主体、误带吉祥物或无关元素，否则判不通过。
2. **透明背景（数值规则）**：以 `alpha` 通道核实，须同时满足：
   - 完全透明像素 `alpha=0` 占比 **≥ 5%**（证明存在透明背景，而非实色底）；
   - 主体不透明像素 `alpha≥250` 占比 **≥ 5%**（证明有实体主体）；
   - 半透明过渡像素占比 **≤ 30%**（定义同上：明显半透明为 `0<alpha<250`，250–255 视为近不透明柔边不计入）。
   可直接运行确定性脚本核对：`python3 docs/avatar-validate.py <path-to-avatar.png>`。
3. **无吉祥物**：不得出现兔子或任何动物形象（抽象人物 / 群像允许）。
4. **配色合规**：主体为白 + 浅粉 + 深蓝描边的扁平卡通风；允许柔和高光，但不得出现投影、大幅渐变或体积光。

任一项不通过即重绘，重绘时可在主体描述后追加 `large and centered, filling most of the square frame` 以纠正主体偏小，或追加更明确的负向约束排除误带吉祥物。
