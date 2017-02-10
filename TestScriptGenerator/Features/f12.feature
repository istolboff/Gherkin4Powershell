Feature: f12
Background: 
    Given Call me Sam
    And Call me Neo
Scenario Outline: s12-1
    When <Number-1> plus <Number-2> gives <SumOfNumbers>
    Then I should have only <Second Customer Name> left as a friend
Examples:
     | Number-1 | Number-2 | SumOfNumbers | Second Customer Name |
     | 1001     | 2002     | 42           | Mike                 |
     | 33       | 123      | 1923         | Peter                |
     | 666      | 1000     | 1000000      | John                 | 
Scenario: s12-2
	Given I have these friends
        | Friend Name | Age | Gender |
        | Sam         | 45  | Male   |
	When I borrow 23 dollars from 
        | Friend Name | Borrow date | 
        | Sam         | 06/25/2017  | 
    Then I should have only Jane left as a friend
