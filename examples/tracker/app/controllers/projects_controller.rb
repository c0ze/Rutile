class ProjectsController < ApplicationController
  PER_PAGE = 20

  before_action :set_project, only: %i[show update destroy archive]

  def index
    projects = current_user.projects.active.order(:name).limit(PER_PAGE).offset((page - 1) * PER_PAGE)
    render json: projects
  end

  def show
    render json: @project.as_json(include: { tasks: { only: %i[id title status] } })
  end

  def create
    project = current_user.owned_projects.create!(project_params)
    render json: project, status: :created
  end

  def update
    @project.update!(project_params)
    render json: @project
  end

  def destroy
    @project.destroy!
    head :no_content
  end

  def archive
    @project.archive!
    render json: @project
  end

  private

  def set_project
    @project = current_user.projects.find(params[:id])
  end

  def project_params
    params.expect(project: %i[name])
  end
end
