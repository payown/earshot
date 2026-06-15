/// Strips HTML tags and decodes HTML entities from [html].
/// Returns an empty string if [html] is null.
///
/// Decodes numeric (`&#8217;`) and hex (`&#x2019;`) character references plus
/// the common named entities found in podcast feeds, so a screen reader never
/// speaks raw entity codes when this text is read aloud.
String stripHtml(String? html) {
  if (html == null || html.isEmpty) return '';
  var text = html.replaceAll(RegExp(r'<[^>]*>'), ' ');

  // Numeric and hex character references.
  text = text.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final code = int.tryParse(m.group(1)!);
    return code != null ? String.fromCharCode(code) : m.group(0)!;
  });
  text = text.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
    final code = int.tryParse(m.group(1)!, radix: 16);
    return code != null ? String.fromCharCode(code) : m.group(0)!;
  });

  // Common named entities. &amp; is decoded last so "&amp;lt;" stays "&lt;".
  const named = {
    '&nbsp;': ' ',
    '&mdash;': '—',
    '&ndash;': '–',
    '&hellip;': '…',
    '&rsquo;': '’',
    '&lsquo;': '‘',
    '&rdquo;': '”',
    '&ldquo;': '“',
    '&apos;': "'",
    '&quot;': '"',
    '&lt;': '<',
    '&gt;': '>',
    '&amp;': '&',
  };
  named.forEach((entity, char) => text = text.replaceAll(entity, char));

  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// A short, plain-text preview of an HTML [description], suitable for reading
/// aloud in a list label. Strips tags/entities and collapses whitespace via
/// [stripHtml], then truncates at a word boundary to [maxChars], appending an
/// ellipsis when it had to cut. Returns an empty string when there's no usable
/// text.
String descriptionPreview(String? description, {int maxChars = 200}) {
  final text = stripHtml(description);
  if (text.length <= maxChars) return text;
  var cut = text.substring(0, maxChars);
  // Only back up to the previous space if the cut actually splits a word; if it
  // landed on a boundary (next char is whitespace) keep the whole cut.
  if (!RegExp(r'\s').hasMatch(text[maxChars])) {
    final lastSpace = cut.lastIndexOf(' ');
    if (lastSpace > 0) cut = cut.substring(0, lastSpace);
  }
  return '${cut.trimRight()}…';
}
