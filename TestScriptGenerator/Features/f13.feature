Feature: f13
Scenario Outline: s13
    Given I have these friends
        | Friend Name | Age | Gender |
        | Sam         | 45  | Male   |
        | Tom         | 18  | Male   |
    When I borrow <Amount> dollars from 
        | Friend Name | Borrow date | 
        | Tom         | 08/13/2016  | 
    Then I should have only Sam left as a friend
Examples:
     | Amount  |
     | 42      |
     | 1923    |
     | 1000000 |
