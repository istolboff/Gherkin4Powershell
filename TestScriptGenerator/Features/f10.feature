Feature: f10
Background: 
    Given I have these friends
        | Friend Name | Age | Gender |
        | Sam         | 45  | Male   |
    And I have these friends
        | Friend Name | Age | Gender |
        | Ann         | 32  | Female |
    And I have these friends
        | Friend Name | Age | Gender |
        | Tom         | 18  | Male   |
    When I borrow 50 dollars from 
        | Friend Name | Borrow date | 
        | Sam         | 06/25/2017  | 
Scenario: s7-1
    When I borrow 40 dollars from 
        | Friend Name | Borrow date | 
        | Tom         | 08/13/2016  | 
    Then I should have only Ann left as a friend
     But everything should be alright
Scenario: s7-2
    Given I have these friends
        | Friend Name | Age | Gender |
        | Bob         | 64  | Male   |
    When I borrow 60 dollars from 
        | Friend Name | Borrow date | 
        | Bob         | 11/05/2018  | 
        | Ann         | 05/12/2015  |
    Then I should have only Tom left as a friend
     But everything should be alright
