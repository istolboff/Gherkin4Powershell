Feature: f11
Scenario Outline: s11
    Given Call me <First Customer Name>
    And Call me <Second Customer Name>
    When <Number-1> plus <Number-2> gives <SumOfNumbers>
    Then I should have only <Second Customer Name> left as a friend
Examples:
     | First Customer Name | Second Customer Name | Number-1 | Number-2 | SumOfNumbers | 
     | Ismael              | Bob                  | 1001     | 2002     | 42           | 
     | John                | James                | 33       | 123      | 1923         | 
     | John Donn           | Samuel L. Jackson    | 666      | 1000     | 1000000      |  
