using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using TechTalk.SpecFlow;

namespace TestScriptGenerator
{
    [Binding]
    public static class LoggingStepDefinitions
    {
        [BeforeTestRun]
        public static void SetupTestRun()
        {
            Trace.WriteLine("(Hook 'BeforeTestRun'),");
        }

        [AfterTestRun]
        public static void TeardownTestRun()
        {
            Trace.WriteLine("(Hook 'AfterTestRun')");
        }

        [BeforeFeature]
        public static void SetupFeature()
        {
            Trace.WriteLine($"(Hook 'BeforeFeature' -withContext @{{ Name = '{FeatureContext.Current.FeatureInfo.Title}'; Description = $Null; Tags = {DescribeTags(FeatureContext.Current.FeatureInfo.Tags)} }}),");
        }

        [AfterFeature]
        public static void TeardownFeature()
        {
            Trace.WriteLine("(Hook 'AfterFeature'),");
        }

        [BeforeScenario]
        public static void SetupScenario()
        {
            Trace.WriteLine($"(Hook 'BeforeScenario' -withContext @{{ Name = '{ScenarioContext.Current.ScenarioInfo.Title}'; Description = $Null; Tags = {DescribeTags(ScenarioContext.Current.ScenarioInfo.Tags)} }}),");
        }

        [AfterScenario]
        public static void TeardownScenario()
        {
            Trace.WriteLine("(Hook 'AfterScenario'),");
        }

        [BeforeScenarioBlock]
        public static void SetupScenarioBlock()
        {
            Trace.WriteLine($"(Hook 'BeforeScenarioBlock' -withContext @{{ BlockType = $StepTypeEnum.{ScenarioContext.Current.CurrentScenarioBlock} }}),");
        }

        [AfterScenarioBlock]
        public static void TeardownScenarioBlock()
        {
            Trace.WriteLine("(Hook 'AfterScenarioBlock'),");
        }

        [BeforeStep]
        public static void SetupStep()
        {
            Trace.WriteLine($"(Hook 'BeforeStep' -withContext @{{ StepType = $StepTypeEnum.{ScenarioContext.Current.StepContext.StepInfo.StepDefinitionType} }}),");
        }

        [AfterStep]
        public static void StepTeardown()
        {
            Trace.WriteLine("(Hook 'AfterStep'),");
        }

        [Given(@"I have these friends")]
        public static void HaveTheseFriends(Table table)
        {
            var rowsData = DescribeTableData(table);

            Trace.WriteLine($"(Step -given 'I have these friends' -tableArgument {DescribeTableData(table)} ),");
        }

        [Given(@"Call me (.*)")]
        public static void CallMeLikeThis(string name)
        {
            Trace.WriteLine($"(Step -given 'Call me Argument({name})'),");
        }


        [When(@"(\d+) plus (\d+) gives (\d+)")]
        public static void SomePlusSomeGivesSome(int first, int second, int sum)
        {
            Trace.WriteLine($"(Step -when 'Argument({first}) plus Argument({second}) gives Argument({sum})'),");
        }

        [When(@"I borrow (.*) dollars from")]
        public static void BorrowDollarsFrom(int amount, Table table)
        {
            Trace.WriteLine($"(Step -when 'I borrow Argument({amount}) dollars from' -tableArgument {DescribeTableData(table)}),");
        }

        [Then(@"I should have only (.*) left as a friend")]
        public static void ShouldHaveOnlyFriend(string friendName)
        {
            Trace.WriteLine($"(Step -then 'I should have only Argument({friendName}) left as a friend'),");
        }

        [Then(@"everything should be alright")]
        public static void ThenEverythingShouldBeAlright()
        {
            Trace.WriteLine("(Step -then 'everything should be alright'),");
        }

        private static string DescribeTags(IReadOnlyCollection<string> tagNames)
        {
            var tags = tagNames.Count == 0
                ? "@()"
                : string.Join(",", ScenarioContext.Current.ScenarioInfo.Tags);
            return tags;
        }

        private static string DescribeTableData(Table table)
        {
            var rowsData = string.Join(
                ", ",
                table.Rows.Select(row => "@{ " + string.Join(
                    "; ",
                    table.Header.Select(columnName => $"'{columnName}' = '{row[columnName] ?? "$Null"}'")) + " }"));

            if (table.RowCount == 1)
            {
                rowsData = "," + rowsData;
            }
            return $"@{{ Header = '{string.Join("', '", table.Header)}'; Rows = {rowsData} }}";
        }
    }
}
