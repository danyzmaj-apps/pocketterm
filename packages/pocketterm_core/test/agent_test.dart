import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/agent.dart';

void main() {
  test("an omp command line's profile, whichever way it's written; none for a name omp wouldn't take", () {
    expect(ompProfileOfArgs('omp --profile=personal'), 'personal');
    expect(ompProfileOfArgs('/opt/homebrew/bin/omp --profile work -c'), 'work');
    expect(ompProfileOfArgs('omp --profile=Work'), '');
    expect(ompProfileOfArgs('omp --profile'), '');
    expect(ompProfileOfArgs('omp --resume /x.jsonl'), '');
    expect(ompProfileOfArgs('omp'), '');
  });

  test('profile names as omp takes them', () {
    expect(isOmpProfile('personal'), isTrue);
    expect(isOmpProfile('a.b_c-1'), isTrue);
    expect(isOmpProfile('a.'), isFalse);
    expect(isOmpProfile('.a'), isFalse);
    expect(isOmpProfile(''), isFalse);
    expect(isOmpProfile('a; rm -rf ~'), isFalse);
    expect(isOmpProfile('a' * 65), isFalse);
  });

  test('only omp runs in a profile, and the default one reads as before', () {
    expect(Agent.omp.commandIn('personal'), 'omp --profile=personal');
    expect(Agent.omp.commandIn(''), 'omp');
    expect(Agent.claude.commandIn('personal'), 'claude');
    expect(Agent.omp.labelIn('personal'), 'omp · personal');
    expect(Agent.omp.labelIn(''), 'omp');
    expect(Agent.claude.labelIn('personal'), 'Claude');
    // As typed once the no-break characters are gone.
    String typed(String s) => s.replaceAll('\u00A0', ' ').replaceAll('\u2060', '');
    expect(typed(Agent.omp.resumeIn('personal')), 'omp --profile=personal -c');
    expect(Agent.omp.resumeIn(''), Agent.omp.resume);
    expect(Agent.claude.pickUpIn('personal'), '/reload-plugins');
  });
}
