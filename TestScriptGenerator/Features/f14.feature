Feature: f14
Scenario Outline: s14
    Given I have these friends
        | Friend Name | Age | Gender |
        | Sam         | 45  | Male   |
        | Tom         | 18  | Male   |
    When I borrow <Amount> dollars from 
        | Friend Name | Borrow date | 
        | <Friend>         | 08/13/2016  | 
    Then I should have only <Friend that is left> left as a friend
Examples:
     | Amount | Friend | Friend that is left |
     | 42     | Sam    | Tom                 |
     | 1923   | Tom    | Sam                 |
