FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src/Inventory
COPY src/Inventory/Inventory.csproj .
RUN dotnet restore
COPY src/DemoSecurity.cs /src/DemoSecurity.cs
COPY src/Inventory/*.cs ./
RUN dotnet publish --configuration Release --no-restore --output /publish

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
RUN install -d -o app -g app /data
COPY --from=build /publish .
USER app
ENV ASPNETCORE_HTTP_PORTS=""
EXPOSE 8080 8443
ENTRYPOINT ["dotnet", "Inventory.dll"]
