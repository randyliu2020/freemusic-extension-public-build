import unittest
from verify_interaction_result import validate


class ActualExecutionCounts(unittest.TestCase):
    def setUp(self):
        self.summary = dict(totalTestCount=2, passedTests=2, failedTests=0,
                            skippedTests=0, result="Passed", testFailures=[])

    def test_two_real_cases_pass(self):
        self.assertEqual(validate(self.summary)["passedTests"], 2)

    def test_zero_partial_skipped_failed_unknown_counts_rejected(self):
        for update in [dict(totalTestCount=0, passedTests=0), dict(totalTestCount=1, passedTests=1),
                       dict(passedTests=1, skippedTests=1), dict(passedTests=1, failedTests=1),
                       dict(passedTests=True), dict(passedTests="2"), dict(result="Failed"),
                       dict(testFailures=[{"failureText": "fixture failure"}])]:
            with self.subTest(update=update), self.assertRaises(ValueError):
                validate(self.summary | update)
        with self.assertRaises(ValueError):
            validate({})
        with self.assertRaises(ValueError):
            validate(None)


if __name__ == "__main__":
    unittest.main()
