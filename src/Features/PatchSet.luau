--!strict
-- PatchSet: Structured representation of changes between Studio and server
-- Ported from Rojo's PatchSet for meaningful change tracking and git commits

export type PatchUpdate = {
	id: string,
	changedName: string?,
	changedClassName: string?,
	changedProperties: { [string]: any },
}

export type PatchSet = {
	removed: { string | Instance },
	added: { [string]: {
		Id: string,
		Name: string,
		ClassName: string,
		Parent: string?,
		Properties: { [string]: any },
		Children: { string },
	} },
	updated: { PatchUpdate },
}

local PatchSet = {}

function PatchSet.newEmpty(): PatchSet
	return {
		removed = {},
		added = {},
		updated = {},
	}
end

function PatchSet.isEmpty(patch: PatchSet): boolean
	return next(patch.removed) == nil and next(patch.added) == nil and next(patch.updated) == nil
end

function PatchSet.countChanges(patch: PatchSet): number
	local count = 0
	for _ in patch.added do count += 1 end
	for _ in patch.removed do count += 1 end
	for _, update in patch.updated do
		for _ in update.changedProperties do count += 1 end
		if update.changedName then count += 1 end
		if update.changedClassName then count += 1 end
	end
	return count
end

function PatchSet.countInstances(patch: PatchSet): number
	local count = 0
	for _ in patch.added do count += 1 end
	for _ in patch.removed do count += 1 end
	for _ in patch.updated do count += 1 end
	return count
end

function PatchSet.merge(target: PatchSet, ...: PatchSet)
	for i = 1, select("#", ...) do
		local source = select(i, ...)
		for _, removed in ipairs(source.removed) do
			table.insert(target.removed, removed)
		end
		for id, added in pairs(source.added) do
			target.added[id] = added
		end
		for _, update in ipairs(source.updated) do
			table.insert(target.updated, update)
		end
	end
	return target
end

-- Generate a human-readable summary of changes (for git commit messages)
function PatchSet.humanSummary(patch: PatchSet, instanceMap: any?): string
	local statements = {}

	for _, idOrInstance in ipairs(patch.removed) do
		if typeof(idOrInstance) == "Instance" then
			table.insert(statements, "Delete " .. idOrInstance:GetFullName())
		elseif instanceMap and instanceMap.fromIds[idOrInstance] then
			table.insert(statements, "Delete " .. instanceMap.fromIds[idOrInstance]:GetFullName())
		else
			table.insert(statements, "Delete instance " .. tostring(idOrInstance))
		end
	end

	for _, addition in pairs(patch.added) do
		table.insert(statements, string.format("Add %s (%s)", addition.Name, addition.ClassName))
	end

	for _, update in ipairs(patch.updated) do
		local props = {}
		if update.changedName then table.insert(props, "Name") end
		if update.changedClassName then table.insert(props, "ClassName") end
		for name in pairs(update.changedProperties) do
			table.insert(props, name)
		end
		local instanceName = update.id
		if instanceMap and instanceMap.fromIds[update.id] then
			instanceName = instanceMap.fromIds[update.id]:GetFullName()
		end
		table.insert(statements, string.format("Update %s: %s", instanceName, table.concat(props, ", ")))
	end

	if #statements == 0 then return "No changes" end
	return table.concat(statements, "; ")
end

return PatchSet
