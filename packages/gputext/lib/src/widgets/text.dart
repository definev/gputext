// GPULabel — convenience mirror of Text built on GPURichText.
// Unlike GPURichText (which matches RichText's raw semantics), this
// applies the ambient DefaultTextStyle and MediaQuery text scaler.

import 'package:flutter/widgets.dart';

import 'rich_text.dart';

class GPULabel extends StatelessWidget {
  const GPULabel(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.textDirection,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.transformAdaptive = true,
    this.scaleHint,
  });

  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final bool transformAdaptive;
  final Listenable? scaleHint;

  @override
  Widget build(BuildContext context) {
    final defaults = DefaultTextStyle.of(context);
    var effectiveStyle = style;
    if (style == null || style!.inherit) {
      effectiveStyle = defaults.style.merge(style);
    }
    Widget result = GPURichText(
      text: TextSpan(text: data, style: effectiveStyle),
      textAlign: textAlign ?? defaults.textAlign ?? TextAlign.start,
      textDirection: textDirection,
      softWrap: softWrap ?? defaults.softWrap,
      overflow: overflow ?? effectiveStyle?.overflow ?? defaults.overflow,
      textScaler: textScaler ?? MediaQuery.textScalerOf(context),
      maxLines: maxLines ?? defaults.maxLines,
      transformAdaptive: transformAdaptive,
      scaleHint: scaleHint,
    );
    if (semanticsLabel != null) {
      result = Semantics(
        textDirection: textDirection,
        label: semanticsLabel,
        child: ExcludeSemantics(child: result),
      );
    }
    return result;
  }
}
