--!nonstrict

local Harness = require("./TestHarness")
local harness = Harness.new()

require("./core.spec")(harness)
require("./frp.spec")(harness)
require("./frp_laws.spec")(harness)
require("./property.spec")(harness)
require("./utility.spec")(harness)
require("./capital.spec")(harness)
require("./facade.spec")(harness)
require("./overdare.spec")(harness)
require("./network.spec")(harness)
require("./multiplayer.spec")(harness)
require("./integration.spec")(harness)

harness:run()
