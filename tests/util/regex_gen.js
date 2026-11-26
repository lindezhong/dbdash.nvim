// Generate tests/util/regex_cases.json with a real ECMAScript engine (dev-only):
//   node tests/util/regex_gen.js
// Patterns use the "u" flag, as JSON Schema's pattern does.
const fs = require("fs");
const cases = [
  ["^a*$", ["", "aaa", "ab"]], ["a+?b", ["aab", "b"]], ["^[0-9]{3}-[0-9]{4}$", ["555-1212", "5551212", "(888)555-1212"]],
  ["^(\\([0-9]{3}\\))?[0-9]{3}-[0-9]{4}$", ["555-1212", "(888)555-1212", "(888)555-1212 ext. 532"]],
  ["^[a-z]+(?:-[a-z]+)*$", ["abc-def", "abc-", "-abc"]], ["\\bfoo\\b", ["a foo b", "afoob", "foo"]], ["\\Bfoo", ["afoo", "foo"]],
  ["^\\d+\\.\\d{2}$", ["12.34", "12.3", "１２.34"]], ["[^\\s]+", ["   ", " x ", " 　"]], ["^\\w+$", ["héllo", "hello_1"]],
  ["^.$", ["é", "\n", "😀", "\r", " "]], ["^(a|ab)(c|bcd)(d*)$", ["abcd"]], ["x{2,}", ["x", "xx"]], ["^x{1,2}$", ["x", "xxx"]],
  ["^\\u00e9$", ["é"]], ["^\\x41\\t$", ["A\t"]], ["^[\\u0041-\\u005A]+$", ["ABC", "aBC"]], ["^(?<y>\\d{4})$", ["2024", "24"]],
  ["^(a+)+$", ["aaaa", "aab"]], ["^[\\d-]+$", ["1-2", "a"]], ["^\\cJ$", ["\n"]], ["^[\\b]$", ["\b"]], ["^\\/\\.$", ["/."]],
  ["^(?:a|)+$", ["aaa", ""]], ["^.*?x", ["abxcx", "abc"]], ["^\\u{1F600}$", ["😀"]], ["^[😀-😂]$", ["😁", "😃"]],
  ["^\\ud83d\\ude00$", ["😀"]], ["^[^a-c]$", ["d", "b"]], ["a|b|", ["", "z"]], ["^(ab|a)(bc|c)?$", ["abc", "ab", "a"]],
  ["^[\\w-]+@[\\w-]+\\.[a-z]{2,}$", ["joe@example.com", "joe@example"]], ["^\\S+$", ["a\tb", "ab"]], ["^\\0$", ["\0"]],
  ["^\\p{Letter}+$", ["héllo", "a1", "中文"]], ["^\\p{L}\\p{Nd}$", ["a٣", "aa"]], ["^\\P{L}$", ["1", "x"]],
  ["^[\\p{Lu}\\d]+$", ["AB1", "aB"]], ["^\\p{gc=Zs}$", ["\u3000", "\t"]], ["^\\p{Sc}$", ["€", "e"]],
  ["^\\W$", ["!", "a"]], ["^\\D\\s\\S$", ["a b", "1 b"]], ["^[.]$", [".", "a"]], ["^a{0}b$", ["b", "ab"]], ["^(x*)*$", ["xxx"]],
];
const invalid = ["^\\p{Script=Greek}$", "(?=a)", "(?!a)", "(?<=a)b", "(?<!a)b", "(a)\\1", "[b-a]", "a{2,1}", "*a", "(a", "a)", "[a", "\\k<x>"];
const out = [];
for (const [p, inputs] of cases) {
  const re = new RegExp(p, "u");
  for (const s of inputs) out.push({ pattern: p, input: s, match: re.test(s) });
}
for (const p of invalid) out.push({ pattern: p, error: true });
fs.writeFileSync(__dirname + "/regex_cases.json", JSON.stringify(out, null, 1) + "\n");
console.log(`wrote ${out.length} cases`);
