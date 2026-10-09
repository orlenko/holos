import Testing
@testable import HolosSynthesis

// The numbers a text says, by value, however they are written.

@Suite struct SpokenNumbersTests {
    @Test func digitsAndWordsGiveTheSameValues() {
        let same: [(String, String)] = [
            ("2015", "two thousand and fifteen"), ("2015", "two thousand fifteen"), ("2015", "twenty fifteen"),
            ("1984", "nineteen eighty four"), ("1500", "fifteen hundred"), ("1,500", "one thousand five hundred"),
            ("2,015", "2015"), ("1\u{00A0}500", "mille cinq cents"), ("1.500", "1500"), ("2015", "deux mille quinze"),
            ("97", "quatre-vingt-dix-sept"), ("80", "quatre-vingts"), ("71", "soixante et onze"),
            ("21", "vingt et un"), ("17", "dix-sept"), ("101", "cent un"), ("3.5", "three point five"),
            ("3,5", "trois virgule cinq"), ("3.14", "three point one four"), ("3.25", "trois virgule vingt-cinq"),
            ("21st", "twenty first"), ("1er", "premier"), ("2nd", "second"), ("1,000,000", "one million"),
            ("1 2 3", "one two three"), ("50 %", "cinquante pour cent"), ("50%", "fifty percent"),
        ]
        for (written, said) in same {
            #expect(SpokenNumbers.values(in: written) == SpokenNumbers.values(in: said), "\(written) / \(said)")
        }
        #expect(SpokenNumbers.values(in: "2015") == ["2015"])
        #expect(SpokenNumbers.values(in: "3,5") == ["3.5"])
    }

    @Test func otherNumbersAreOtherValues() {
        #expect(SpokenNumbers.values(in: "twenty") != SpokenNumbers.values(in: "2015"))
        #expect(SpokenNumbers.values(in: "garbage").isEmpty)
        #expect(SpokenNumbers.values(in: "2016") != SpokenNumbers.values(in: "two thousand fifteen"))
        #expect(SpokenNumbers.values(in: "1500 2000") == ["1500", "2000"])
    }
}
