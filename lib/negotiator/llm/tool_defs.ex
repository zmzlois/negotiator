defmodule Negotiator.LLM.ToolDefs do
  @moduledoc """
  tool schemas for llm function calling. maps tasks to eligible tools.
  """

  @web_search %{
    type: "function",
    function: %{
      name: "web_search",
      description:
        "search the web for current information about companies, markets, people, or recent events. " <>
          "use when you need to verify a claim, look up market data, or find context about a topic.",
      parameters: %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "the search query"}
        },
        required: ["query"]
      }
    }
  }

  @verify_claim %{
    type: "function",
    function: %{
      name: "verify_claim",
      description:
        "fact-check a specific claim the founder just made. searches for evidence that " <>
          "confirms or contradicts the claim. use when the founder states a market size, " <>
          "user count, growth rate, or competitive position that sounds inflated or unverified.",
      parameters: %{
        type: "object",
        properties: %{
          claim: %{type: "string", description: "the exact claim to verify"},
          context: %{type: "string", description: "what the founder said around this claim"}
        },
        required: ["claim"]
      }
    }
  }

  @competitor_lookup %{
    type: "function",
    function: %{
      name: "competitor_lookup",
      description:
        "deep dive on a specific competitor. returns funding history, key features, pricing, " <>
          "and recent news. use when the founder mentions a competitor or claims no competition exists.",
      parameters: %{
        type: "object",
        properties: %{
          company: %{type: "string", description: "competitor company name"},
          aspect: %{
            type: "string",
            enum: ["funding", "product", "pricing", "news", "all"],
            description: "what aspect to focus on"
          }
        },
        required: ["company"]
      }
    }
  }

  @calculate_unit_economics %{
    type: "function",
    function: %{
      name: "calculate_unit_economics",
      description:
        "compute unit economics from numbers the founder provides. calculates CAC payback, " <>
          "LTV/CAC ratio, burn rate, runway, dilution, and break-even. use when the founder " <>
          "shares revenue, pricing, costs, or round size numbers.",
      parameters: %{
        type: "object",
        properties: %{
          metrics: %{
            type: "object",
            description: "any numbers the founder mentioned",
            properties: %{
              revenue_monthly: %{type: "number", description: "monthly revenue in dollars"},
              customers: %{type: "number", description: "number of paying customers"},
              price_per_unit: %{type: "number", description: "price per seat/unit/month"},
              cac: %{type: "number", description: "customer acquisition cost"},
              burn_monthly: %{type: "number", description: "monthly burn rate"},
              cash_on_hand: %{type: "number", description: "current cash balance"},
              round_size: %{type: "number", description: "amount raising"},
              pre_money_valuation: %{type: "number", description: "pre-money valuation"},
              growth_rate_monthly: %{type: "number", description: "month-over-month growth %"}
            }
          }
        },
        required: ["metrics"]
      }
    }
  }

  @search_recent_news %{
    type: "function",
    function: %{
      name: "search_recent_news",
      description:
        "find recent news in the founder's space for curveball questions. searches for " <>
          "acquisitions, product launches, regulatory changes, or competitor moves from the last 30 days. " <>
          "use to throw informed curveballs like 'did you see that X just announced Y?'",
      parameters: %{
        type: "object",
        properties: %{
          topic: %{type: "string", description: "the market or technology area to search"},
          angle: %{
            type: "string",
            enum: ["acquisitions", "launches", "regulation", "funding", "failures"],
            description: "what kind of news to focus on"
          }
        },
        required: ["topic"]
      }
    }
  }

  @moss_search %{
    type: "function",
    function: %{
      name: "moss_search",
      description:
        "search the call transcript and knowledge base for what was said earlier in this conversation. " <>
          "use to recall exact quotes, review what the investor asked, check what the founder claimed, " <>
          "or find context from prior turns. can filter by speaker role.",
      parameters: %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "what to search for in the transcript"},
          role: %{
            type: "string",
            enum: ["founder", "investor", "negotiation_agent", "small_talk_agent"],
            description: "filter results to a specific speaker role"
          }
        },
        required: ["query"]
      }
    }
  }

  @investor_tools [@web_search, @verify_claim, @competitor_lookup, @calculate_unit_economics, @search_recent_news]

  def for_task(:investor_turn), do: @investor_tools
  def for_task(:small_talk_reply), do: [@web_search, @moss_search]
  def for_task(:negotiation_advice), do: [@moss_search, @web_search]
  def for_task(_task), do: []
end
