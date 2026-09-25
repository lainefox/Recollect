// FuzzyMatcher — fuzzy (subsequence) matching with relevance scoring.
//
// A candidate matches when every character of the query appears in the text in
// order, though not necessarily next to each other, so "rclct" still finds
// "Recollect".  Matches are scored so that the closest ones rank first: a
// contiguous hit at a word start outranks a contiguous hit inside a word, which
// outranks scattered characters.  Ties are broken by how early the match starts,
// how tightly the characters line up, and how short the text is.
//
// Matching is byte-oriented and folds ASCII case only, which is exactly what
// SQLite's LIKE does in the non-fuzzy path, so both modes agree on what a query
// matches.  Reported offsets are byte offsets into the searched text.

// One successful fuzzy match: the relevance score (lower is better) and the byte
// offsets of the matched characters, in ascending order.
public class FuzzyMatch : Object {
		public double score { get; construct; }
		public int[] positions;

		public FuzzyMatch(double score, int[] positions) {
				Object(score: score);
				this.positions = positions;
		}
}

public class FuzzyMatcher : Object {
		// Relevance bands. A candidate in a better band always outranks every
		// candidate in a worse one, so the weights below can never spill over.
		private const double TIER_SUBSTRING = 0.0;        // query characters sit next to each other
		private const double TIER_WORD_START = 1000000.0; // scattered, but starting at a word boundary
		private const double TIER_SCATTERED = 2000000.0;   // scattered anywhere

		// A hit that does not start at a word boundary is penalised by more than
		// every in-band term can add up to, so a substring inside a word still
		// outranks a scattered hit that happens to start on a word boundary.
		private const double PENALTY_MID_WORD = 500000.0;

		// In-band terms, each clamped so their sum stays well below the gap to
		// the next band: 500*300 + 50*2000 + 1000*50 + 20000*0.025 = 301000.
		private const double WEIGHT_SKIPPED = 300.0;  // characters jumped over inside the match
		private const double WEIGHT_JUMPS = 2000.0;   // number of times the match had to skip ahead
		private const double WEIGHT_START = 50.0;     // distance to the first matched character
		private const double WEIGHT_LENGTH = 0.025;   // length of the candidate text

		// How many starting points a match is attempted at. Trying more than one
		// keeps the score from settling for the first, sloppiest occurrence of
		// the query's first character.
		private const int MAX_TRIES = 8;

		// Drop whitespace from a query and fold its case, so it is exactly what
		// match() looks for. A query of nothing but whitespace becomes empty,
		// which disables fuzzy matching.
		public static string prepare_query(string query, bool match_case) {
				var builder = new GLib.StringBuilder();
				var bytes = query.data;
				for(int i = 0; i < bytes.length; i++) {
						uint8 b = bytes[i];
						if(b == ' ' || b == '\t' || b == '\n' || b == '\r') {
								continue;
						}
						builder.append_c(match_case ? (char) b : (char) fold(b));
				}
				return builder.str;
		}

		// Match a query prepared with prepare_query() against @text. Returns null
		// when @text does not contain all of the query characters in order,
		// otherwise the best relevance score and the offsets of its characters.
		public static FuzzyMatch? match(string query, string text, bool match_case) {
				int needle_length = query.length;
				if(needle_length == 0 || needle_length > text.length) {
						return null;
				}

				var offsets = new int[needle_length];
				int[] best_offsets = null;
				double best_score = 0.0;

				// Always score an exact substring hit, even when it sits behind
				// more than MAX_TRIES copies of the query's first character.
				int exact = index_of_bytes(text, query, 0, match_case);
				if(exact >= 0) {
						double score;
						if(try_match(text, query, needle_length, match_case, exact, offsets, out score)) {
								best_offsets = copy_offsets(offsets, needle_length);
								best_score = score;
						}
				}

				// Then look for a better, scattered match at the next few
				// occurrences of the query's first character.
				int tries = 0;
				int from = 0;
				while(tries < MAX_TRIES && from < text.length) {
						int start = index_of_byte(text, query[0], from, match_case);
						if(start < 0) {
								break;
						}
						tries++;

						double score;
						if(try_match(text, query, needle_length, match_case, start, offsets, out score)
									&& (best_offsets == null || score < best_score)) {
								best_offsets = copy_offsets(offsets, needle_length);
								best_score = score;
						}

						from = start + 1;
				}

				if(best_offsets == null) {
						return null;
				}
				return new FuzzyMatch(best_score, best_offsets);
		}

		// Byte length of the UTF-8 character starting at @offset.
		public static int char_length_at(string text, int offset) {
				uint8 b = text[offset];
				if(b < 0x80) return 1;
				if(b < 0xe0) return 2;
				if(b < 0xf0) return 3;
				return 4;
		}

		// The offsets of the best match so far have to outlive the scratch array
		// they were scanned into, so keep a copy of them.
		private static int[] copy_offsets(int[] offsets, int length) {
				var copy = new int[length];
				for(int i = 0; i < length; i++) {
						copy[i] = offsets[i];
				}
				return copy;
		}

		// Greedy left-to-right scan starting at @start, writing the byte position
		// of every matched character into @offsets. Returns false when @text does
		// not contain the rest of the query, otherwise the relevance score.
		private static bool try_match(string text, string query, int needle_length,
																	bool match_case, int start,
																	int[] offsets, out double score) {
				score = 0.0;

				int matched = 0;
				int last = -1;
				for(int i = start; i < text.length && matched < needle_length; i++) {
						if(fold_unless(match_case, text[i]) == query[matched]) {
								offsets[matched] = i;
								last = i;
								matched++;
						}
				}
				if(matched < needle_length) {
						return false;
				}

				int first = offsets[0];
				int skipped = last - first + 1 - needle_length;

				int jumps = 0;
				for(int i = 1; i < needle_length; i++) {
						if(offsets[i] != offsets[i - 1] + 1) {
								jumps++;
						}
				}

				bool word_start = first == 0 || !is_word_byte(text[first - 1]);

				if(skipped == 0) {
						score = TIER_SUBSTRING;
				} else if(word_start) {
						score = TIER_WORD_START;
				} else {
						score = TIER_SCATTERED;
				}

				if(!word_start) {
						score += PENALTY_MID_WORD;
				}
				score += int.min(skipped, 500) * WEIGHT_SKIPPED;
				score += int.min(jumps, 50) * WEIGHT_JUMPS;
				score += int.min(first, 1000) * WEIGHT_START;
				score += int.min(text.length, 20000) * WEIGHT_LENGTH;

				return true;
		}

		// ASCII case folding, matching what SQLite's LIKE does for the non-fuzzy
		// path.
		private static uint8 fold(uint8 b) {
				return (b >= 'A' && b <= 'Z') ? (uint8) (b + 32) : b;
		}

		private static uint8 fold_unless(bool match_case, uint8 b) {
				return match_case ? b : fold(b);
		}

		// Bytes that belong to a word: ASCII letters, digits, underscore, and
		// anything >= 0x80, which is part of a multi-byte character.
		private static bool is_word_byte(uint8 b) {
				return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
						|| b == '_' || b >= 0x80;
		}

		// Index of the first @needle at or after @from, folding ASCII case of
		// @text when @match_case is false. The needle itself is always folded
		// already, by prepare_query().
		private static int index_of_byte(string text, uint8 needle, int from, bool match_case) {
				for(int i = from; i < text.length; i++) {
						if(fold_unless(match_case, text[i]) == needle) {
								return i;
						}
				}
				return -1;
		}

		// Index of the first occurrence of @needle at or after @from, folding
		// ASCII case of @text when @match_case is false.
		private static int index_of_bytes(string text, string needle, int from, bool match_case) {
				int last = text.length - needle.length;
				for(int i = from; i <= last; i++) {
						if(fold_unless(match_case, text[i]) != needle[0]) {
								continue;
						}
						int j = 1;
						while(j < needle.length && fold_unless(match_case, text[i + j]) == needle[j]) {
								j++;
						}
						if(j == needle.length) {
								return i;
						}
				}
				return -1;
		}
}
