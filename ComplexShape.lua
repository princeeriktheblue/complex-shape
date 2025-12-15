local ComplexShape = {}
ComplexShape.__index = ComplexShape

local CollectionService = game:GetService("CollectionService")

local MAX_ALLOWED_FAILS = 10
local MAX_HEIGHT_TOLERANCE = 100

local abs, cos, sin, acos = math.abs, math.cos, math.sin, math.acos

local function GetDistanceFromLine(line_point : Vector3, direction : Vector3, point : Vector3) : number
	return (point - line_point):Cross(direction).Magnitude/direction.Magnitude
end

local function GetAngleFromVector(vectorA : Vector3, vectorB : Vector3)
	local angle = vectorA:Dot(vectorB)/(vectorA.Magnitude * vectorB.Magnitude)
	if abs(angle) > 1 then return nil end
	return acos(angle)
end

--The params to be used
export type SpawnGenerationParams = {
	Min : number?,
	Max : number?,
	Points : number?,
	Distance : number?,
	Height : number?,
	AreaTolerance : Vector3?,
}

--[[
	This constructs the complex shape. It takes a center position, and the vector positions of its corners to create an object. All of these vector points will have their
	Y component adjusted to match the center positions Y. Height is determined to be the maximum height, higher than or lower than the center, to be allowed to be considered within this shape.
	Vector points mustd be equal to or more than 3; after all 2 points is just a line, and there is no area in a 2d or 3d space to be solvable in such a scenario.
	
	The Y component of the position will be considered the absolute BOTTOM position. Meaning the following:

	If your positions Y component is 10, and you have a set height of 10, the Y values that are considered inside are 10-20.
	
	Position -> The position of the center, Vector3
	VectorPoints -> The points around the center, table of Vector3 values, may not be a dictionary
	Height -> the maximum height height of the capture area; both above and below the median.
]]
function ComplexShape.new(Position : Vector3, VectorPoints : {Vector3}, Height : number)
	--Checks input to make sure it works and follows the above restrictions
	assert(typeof(Position) == "Vector3", "Position must be of type Vector3")
	assert(VectorPoints and #VectorPoints >= 3, "VectorPoints must be a non dictionary list of at least 3 elements")
	assert(typeof(Height) == "number", "Height must be of type number")
	
	--Sets metatable
	local self = setmetatable({}, ComplexShape)
	
	--Position is set
	self.Position = Position
	
	--Normalizes and indexes all vectors to the Y component
	self.VectorPoints = {}
	for index, value : Vector3 in pairs(VectorPoints) do
		self.VectorPoints[index] = Vector3.new(value.X, Position.Y, value.Z)
	end
	
	--Saving variables to the metatable, also founds the center Y
	self.NumVectors = #VectorPoints
	self.Height = Height
	self.CenterY = self.Position.Y + self.Height/2
	
	self.MaxDist = 0
	self.MinDist = math.huge
	
	for index,value in pairs(self.VectorPoints) do
		local dist = (self.Position - value).Magnitude
		if dist < self.MinDist then
			self.MinDist = dist
		end
		if dist > self.MaxDist then
			self.MaxDist = dist
		end
	end
	
	--Indexing extremes of max and min distances, for future calculations to be easier/faster.
	for i=1, self.NumVectors-1, 1 do
		local firstPos = self.VectorPoints[i]
		local secondPos = self.VectorPoints[i+1]
		local dist = GetDistanceFromLine(firstPos, secondPos - firstPos, Position)
		if dist < self.MinDist then
			self.MinDist = dist
		end

		local dist_from_pt = (secondPos - Position).Magnitude
		if dist_from_pt > self.MaxDist then
			self.MaxDist = dist_from_pt
		end
	end

	local firstPos = self.VectorPoints[self.NumVectors]
	local secondPos = self.VectorPoints[1]
	local dist = GetDistanceFromLine(firstPos, secondPos - firstPos, Position)
	if dist < self.MinDist then
		self.MinDist = dist
	end

	local dist_from_pt = (secondPos - Position).Magnitude
	if dist_from_pt > self.MaxDist then
		self.MaxDist = dist_from_pt
	end

	return self
end

--[[
	This local function calculates the point of interception and transforms it into a Vector3 which is normalized to the Y
	position of the area
]]
local function intersection(start1 : Vector3, end1 : Vector3, start2 : Vector3, end2 : Vector3, yCoord : number)
	local d = (start1.X - end1.X) * (start2.Z - end2.Z) - (start1.Z - end1.Z) * (start2.X - end2.X)
	local a = start1.X * end1.Z - start1.Z * end1.X
	local b = start2.X * end2.Z - start2.Z * end2.X
	return Vector3.new((a * (start2.X - end2.X) - (start1.X - end1.X) * b) / d, yCoord, (a * (start2.Z - end2.Z) - (start1.Z - end1.Z) * b) / d)
end

--[[
	Checks whether or not the Position is inde of the complex shape. The Maximum distance tolerance allows for wiggle room inside or outside of the area. This should
	be utilized in situations where replication delays may impact gameplay.
	
	Position -> the position to check on
	MAX_DISTANCE_TOLERANCE -> The maximum distance tolerance allowable from the edge of every part of the complex shape.
	
	returns whether the position is inside of the area.
]]
function ComplexShape:IsInside(Position : Vector3, MAX_DISTANCE_TOLERANCE : number?)
	assert(typeof(Position) == "Vector3", "Position must be of type Vector3")
	
	--If the second parameter is not passed, it sets it to 0
	if not MAX_DISTANCE_TOLERANCE then MAX_DISTANCE_TOLERANCE = 0 end
	
	--Checks whether the Y component is acceptable.
	if abs(Position.Y - self.CenterY) > self.Height/2 + MAX_DISTANCE_TOLERANCE then return false end
	
	--Calculates the distance from the center, with a normalized Y, so there is no differentiation from the edge based on height
	Position = Vector3.new(Position.X, self.Position.Y, Position.Z)
	local center_dist = (self.Position - Position).Magnitude
	
	--Checks against the distance to see if we really need to do any of the fancy math below. No reason to take up computation space if it's impossible to be inside or to not be inside, after all.
	if center_dist <= self.MinDist then return true elseif center_dist > self.MaxDist + MAX_DISTANCE_TOLERANCE then return false end
	
	--The following finds the closest vector point
	local closest = self.VectorPoints[1]
	local dist = (Position - closest).Magnitude
	local index = 1

	for i=2, self.NumVectors do
		local next_vec = self.VectorPoints[i]
		local next_dist = (Position - next_vec).Magnitude
		if next_dist < dist then
			closest = next_vec
			dist = next_dist
			index = i
		end
	end
	
	--This finds the vector points attached to that closest vector
	local below,above

	if index == 1 then
		below = self.VectorPoints[self.NumVectors]
		above = self.VectorPoints[2]
	elseif index == self.NumVectors then
		below = self.VectorPoints[self.NumVectors-1]
		above = self.VectorPoints[1]
	else
		below = self.VectorPoints[index - 1]
		above = self.VectorPoints[index + 1]
	end
	
	--Finds the intersection of the two lines, checks their distance against the distance of the player. If both intersections are greater than the player distance, the player is obviously within the lines.
	--Otherwise, the player is outside. This may have potentially exclusive edge cases; which I may or may not need to find out, however none have been identified thus far.
	return center_dist <= math.min((intersection(closest, above, self.Position, Position, self.Position.Y) - self.Position).Magnitude, 
		(intersection(below, closest, self.Position, Position, self.Position.Y) - self.Position).Magnitude) + MAX_DISTANCE_TOLERANCE
end


--[[
	Function for generating a position with the given parameters. This function checks to make sure the spawn point is within a reasonable height from the center point,
	as well as checking against other points to make sure the distance between is not too small. It will also, if checkPos is checked to be true, check to make sure that the
	point spawned is not inside of a block.
	
	Shape -> The shape object
	min -> Minimum distance from the center
	max -> Maximum distance from the center
	minDistFromPoints -> Minimum distance from each point
	checkInside -> Check to make sure the spawn point is inside of the spawn area
	height -> The height from the ground the spawn should be placed
	areaTolerance -> The size of the area that should be checked for blockages
	Spawns -> Prior generated spawns to check against
]]

local function generate_position(Shape, Params : SpawnGenerationParams, checkInside : boolean, Spawns : {Vector3})
	local valid = true
	local angle = math.rad(math.random(0, 3600)/10)
	local dist = Params.Min + (math.random(0, 100)/100 * (Params.Max - Params.Min))
	local position : Vector3 = Shape.Position + Vector3.new(cos(angle), 0, sin(angle)).Unit * dist

	if Params and not Shape:IsInside(position) then return end

	for _, spawnPos in pairs(Spawns) do
		if (spawnPos - position).Magnitude <= Params.Distance then
			return
		end
	end

	if Params.Height then
		local RP = RaycastParams.new()
		RP.FilterType = Enum.RaycastFilterType.Exclude
		RP.IgnoreWater = true
		RP.RespectCanCollide = true
		RP.FilterDescendantsInstances = {CollectionService:GetTagged("NonCollide")}

		--Make height off by 1 to ensure a result
		local hit : RaycastResult = workspace:Raycast(position + Vector3.new(0,Params.Height,0), Vector3.new(0,-MAX_HEIGHT_TOLERANCE + 1,0), RP)

		if not hit or not hit.Instance or hit.Distance > MAX_HEIGHT_TOLERANCE then return end

		position = hit.Position + Vector3.new(0,Params.Height,0)
	end

	if Params.AreaTolerance then
		local OP = OverlapParams.new()
		OP.MaxParts = 1
		OP.RespectCanCollide = true
		OP.FilterType = Enum.RaycastFilterType.Include
		OP.FilterDescendantsInstances = {workspace.Terrain:GetChildren()}

		local instances = workspace:GetPartBoundsInBox(CFrame.new(position), Params.AreaTolerance, OP)
		if #instances ~= 0 then return end
	end

	return position
end

local function checkParams(Params : SpawnGenerationParams)
	if not Params then Params = {} return end
	assert(not Params.Min or typeof(Params.Min) == "number", "The min value must be of type number")
	assert(not Params.Min or Params.Min >= 0, "The min value must be greater than or equal to zero")
	assert(not Params.Max or typeof(Params.Max) == "number", "The min value must be of type number")
	assert(not Params.Min or not Params.Max or Params.Min <= Params.Max, "The min value must be less than or equal the max value")
	assert(not Params.Points or typeof(Params.Points) == "number", "Points must be of type number")
	assert(not Params.Points or Params.Points > 0, "Points must be greater than zero")
	assert(not Params.Distance or typeof(Params.Distance) == "number", "Distance must be of type number")
	assert(not Params.Distance or Params.Distance >= 0, "Distance must be greater than or equal to zero")
	assert(not Params.Height or typeof(Params.Height) == "number", "Height must be of type number")
	assert(not Params.Height or Params.Height >= 0, "Height must be greater than or equal to zero")
	assert(not Params.AreaTolerance or typeof(Params.AreaTolerance) == "Vector3", "Area Tolerance must be of type Vector3")
	assert(not Params.AreaTolerance or (Params.AreaTolerance.X >= 0 and Params.AreaTolerance.Y >= 0 and Params.AreaTolerance.Z >= 0), "AreaTolerance must have all positive values for all fields")
end

function ComplexShape:GenerateSpawnsInside(Params : SpawnGenerationParams)
	if Params then checkParams(Params) else Params = {} end

	if not Params.Min then Params.Min = 0 end
	if not Params.Max then Params.Max = self.MinDist end
	if not Params.Points then Params.Points = 10 end
	if not Params.Distance then Params.Distance = 4 end

	local Spawns = {}
	local numFails = 0

	repeat
		local pos = generate_position(self, Params, true, Spawns)
		if pos then table.insert(Spawns, pos) else numFails = numFails + 1 end

	until #Spawns == Params.Points or numFails >= MAX_ALLOWED_FAILS

	if #Spawns > 0 then return Spawns else return nil end
end

--[[
	Generates spawnpoints outside of the capture area. 
	
	min -> lowest distance a spawn is allowable outside the area
	max -> how far away it should generate spawns
	numPoints -> How many spawn points to generate
	checkPos -> Check to make sure this isn't inside of an object
	
]]

--generate_position(Shape, min : number, max : number, minDistFromPoints : number, checkInside : boolean, height : number, areaTolerance : Vector3, Spawns : {Vector3})
function ComplexShape:GenerateSpawnsOutside(Params : SpawnGenerationParams)
	if Params then checkParams(Params) else Params = {} end

	if not Params.Min then Params.Min = 0 end
	if not Params.Max then Params.Max = 15 end
	if not Params.Points then Params.Points = 10 end
	if not Params.Distance then Params.Distance = 4 end

	local MinRadius = self.MaxDist + Params.Min
	local MaxRadius = self.MaxDist + Params.Max

	local Spawns = {}
	local numFails = 0

	repeat
		local pos = generate_position(self, Params, false, Spawns)
		if pos then table.insert(Spawns, pos) else numFails = numFails + 1 end

	until #Spawns == Params.Points or numFails >= MAX_ALLOWED_FAILS

	if #Spawns > 0 then return Spawns else return nil end
end

return ComplexShape
