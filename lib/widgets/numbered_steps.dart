import 'package:flutter/material.dart';

/// A short list of steps for a parent to follow. More than one step shows as
/// a numbered list ("1.", "2.", …) with the numbers in their own column, so
/// wrapped lines stay lined up. A single step is just centered text.
class NumberedSteps extends StatelessWidget {
  const NumberedSteps({super.key, required this.steps, this.style});

  final List<String> steps;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    if (steps.length == 1) {
      return Text(steps.single, textAlign: TextAlign.center, style: style);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == steps.length - 1 ? 0 : 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 24, child: Text('${i + 1}.', style: style)),
                Expanded(child: Text(steps[i], style: style)),
              ],
            ),
          ),
      ],
    );
  }
}
